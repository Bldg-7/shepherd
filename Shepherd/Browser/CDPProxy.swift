#if os(macOS)
import AppKit
import Observation
import Security
import CoreFoundation
import Darwin

typealias BrowserUploadPathTransform = @MainActor (BrowserKey, [String]) async throws -> [String]
typealias BrowserDownloadObserver = @MainActor (BrowserKey, [String: Any]) -> Void

/// The public endpoint contains no secret. Phase 3 reads the referenced 0600
/// file on the agent host; CEF has no debugging TCP listener.
nonisolated struct BrowserEndpoint: Sendable {
    enum Origin: Hashable, Sendable { case local }
    let origin: Origin
    let host: String
    let port: Int
    let path: String
    let tokenFile: URL
    var url: URL { URL(string: "ws://\(host):\(port)\(path)")! }
}

@MainActor @Observable
final class CDPProxy {
    static let shared = CDPProxy(store: .shared)
    private let store: BrowserStore
    private(set) var port: Int?
    private(set) var error: String?
    private(set) var activeConnections = 0
    var isPreventingAppNap: Bool { activity != nil }
    /// Includes pending admission and retiring/quarantined native leases.
    var hasBrowserWork: Bool { starting || !waitingSockets.isEmpty || !connections.isEmpty }
    #if DEBUG
    var observedChildTargetTypes: Set<String> { Set(connections.values.flatMap { $0.observedChildTargetTypes }) }
    #endif
    /// Host file adapters install these at the proxy, not in a second
    /// identity store. Nil upload adapter is local-only passthrough; remote
    /// origins remain unavailable until their network/file adapter exists.
    @ObservationIgnored var transformUploadPaths: BrowserUploadPathTransform?
    @ObservationIgnored var downloadDidChange: BrowserDownloadObserver?
    /// Install before start; absent broker integration denies credential routes.
    @ObservationIgnored var credentialService: CredentialCLIService?
    @ObservationIgnored private var listener: CDPListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: PaneCDPConnection] = [:]
    @ObservationIgnored private var connectionRoutes: [ObjectIdentifier: CDPRoute] = [:]
    @ObservationIgnored private let routeLeases = CDPRouteLeases()
    private struct WaitingSocket {
        let route: CDPRoute
        let socket: CDPWebSocket
        var messages: [String]
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var waitingSockets: [ObjectIdentifier: WaitingSocket] = [:]
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var tokenFile: URL?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var acceptingConnections = true
    @ObservationIgnored private var token = ""

    init(store: BrowserStore) { self.store = store }

    func start(port requestedPort: Int = 9333) async {
        guard ShepherdBrowserFeature.shared.isEnabled, listener == nil, !starting, BrowserEngine.isAvailable else { return }
        starting = true
        defer { starting = false }
        do {
            guard (0...65535).contains(requestedPort) else { throw ProxyError("Port must be between 1 and 65535.") }
            try FileManager.default.createDirectory(at: store.rootFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ProxyError("Could not create browser authentication token.")
            }
            token = Data(bytes).base64EncodedString()
            let file = store.rootFolder.appending(path: "agent-token")
            // Atomic replacement never follows a stale file/symlink and never
            // briefly exposes a world-readable credential.
            let temp = store.rootFolder.appending(path: ".token-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: temp.path, contents: Data(token.utf8),
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw ProxyError("Could not write browser authentication token.")
            }
            guard rename(temp.path, file.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw ProxyError("Could not replace browser authentication token.")
            }
            tokenFile = file
            let server = CDPListener()
            port = try await server.start(port: requestedPort, token: token, authorizeRoute: { [weak self] route in
                self?.authorized(route) == true
            }, accept: { [weak self] route, socket, text in
                self?.receive(route: route, socket: socket, text: text)
            }, credentialService: credentialService)
            listener = server
            acceptingConnections = true
            error = nil
        } catch {
            self.error = "Browser agent listener could not start on loopback port \(requestedPort): \(error.localizedDescription)"
            port = nil
        }
    }

    func restart(port: Int) async { await stop(); await start(port: port) }

    func endpoint(for key: BrowserKey) -> BrowserEndpoint? {
        guard ShepherdBrowserFeature.shared.isEnabled, let port, let tokenFile, MachineBrowserService.shared.isLocal(key) else { return nil }
        let escaped = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:~"))
        let path = "/v1/herdr/\(key.session.addingPercentEncoding(withAllowedCharacters: escaped)!)/pane/\(key.paneID.addingPercentEncoding(withAllowedCharacters: escaped)!)"
        return BrowserEndpoint(origin: .local, host: "127.0.0.1", port: port, path: path, tokenFile: tokenFile)
    }

    private func authorized(_ route: CDPRoute) -> Bool {
        guard ShepherdBrowserFeature.shared.isEnabled, acceptingConnections,
              let resolved = MachineBrowserService.shared.resolve(route) else { return false }
        return routeLeases.permits(route, terminalID: resolved.terminalID)
    }

    func claimRoute(for key: BrowserKey, terminalID: String, authorize: @escaping () -> Bool) throws -> CDPRouteLeases.Claim {
        guard let endpoint = endpoint(for: key), let route = CDPRoute(endpoint.path),
              MachineBrowserService.shared.resolve(route)?.terminalID == terminalID else { throw ProxyError("Pane admission unavailable.") }
        let claim = try routeLeases.claim(route, terminalID: terminalID, authorize: authorize)
        for pending in waitingSockets.values where pending.route.basePath == route.basePath { pending.task.cancel(); pending.socket.close() }
        for (id, connection) in connections where connectionRoutes[id]?.basePath == route.basePath { connection.close() }
        return claim
    }
    func openRoute(_ claim: CDPRouteLeases.Claim) throws -> BrowserEndpoint {
        guard let port, let tokenFile, MachineBrowserService.shared.resolve(claim.route)?.terminalID == claim.terminalID,
              ShepherdBrowserFeature.shared.isEnabled, acceptingConnections,
              !waitingSockets.values.contains(where: { $0.route.basePath == claim.route.basePath }),
              !connectionRoutes.values.contains(where: { $0.basePath == claim.route.basePath }) else { throw ProxyError("Pane admission unavailable.") }
        let route = try routeLeases.open(claim)
        return BrowserEndpoint(origin: .local, host: "127.0.0.1", port: port, path: route.versionedPath, tokenFile: tokenFile)
    }
    func revokeRoute(_ route: CDPRoute) {
        routeLeases.revoke(route)
        // Keep cancelled admission tasks tracked until their defer runs. A
        // cancelled waiter must not be mistaken for acknowledged native cleanup.
        for pending in waitingSockets.values where pending.route == route { pending.task.cancel(); pending.socket.close() }
        for (id, connection) in connections where connectionRoutes[id] == route { connection.close() }
    }
    func retireRoute(_ claim: CDPRouteLeases.Claim) {
        routeLeases.retire(claim)
        for pending in waitingSockets.values where pending.route.basePath == claim.route.basePath { pending.task.cancel(); pending.socket.close() }
        for (id, connection) in connections where connectionRoutes[id]?.basePath == claim.route.basePath { connection.close() }
    }
    func releaseRoute(_ claim: CDPRouteLeases.Claim) throws {
        guard !waitingSockets.values.contains(where: { $0.route.basePath == claim.route.basePath }),
              !connectionRoutes.values.contains(where: { $0.basePath == claim.route.basePath }) else { throw ProxyError("Native retirement unconfirmed.") }
        try routeLeases.release(claim)
    }
    func closeRoute(_ route: CDPRoute) async throws {
        revokeRoute(route)
        let deadline = ContinuousClock().now.advanced(by: .seconds(16))
        while waitingSockets.values.contains(where: { $0.route == route }) || connectionRoutes.values.contains(route) {
            guard ContinuousClock().now < deadline,
                  !connections.contains(where: { connectionRoutes[$0.key] == route && $0.value.cleanupFailed }) else { throw ProxyError("Native retirement unconfirmed.") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func routeIsQuiescent(_ route: CDPRoute) -> Bool {
        authorized(route) && !waitingSockets.values.contains(where: { $0.route == route }) &&
            connections.allSatisfy { connectionRoutes[$0.key] != route || $0.value.isQuiescent }
    }

    private func receive(route: CDPRoute, socket: CDPWebSocket, text: String?) {
        let id = ObjectIdentifier(socket)
        guard let text else {
            waitingSockets.removeValue(forKey: id)?.task.cancel()
            connections[id]?.close(); return
        }
        guard authorized(route) else { socket.close(); connections[id]?.close(); return }
        if let connection = connections[id] { connection.receive(text); return }
        if waitingSockets[id] != nil {
            guard waitingSockets[id]!.messages.count < 256,
                  text.utf8.count <= CDPPolicy.maximumMessageBytes else { socket.close(); return }
            waitingSockets[id]?.messages.append(text); return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { waitingSockets[id] = nil }
            guard let resolved = MachineBrowserService.shared.resolve(route),
                  let key = store.canonicalKey(for: resolved.key),
                  MachineBrowserService.shared.isLocal(key) else { socket.close(); return }
            if !store.hasBrowser(for: key) { store.openBrowser(for: key, terminalID: resolved.terminalID) }
            guard let browser = store.browser(for: key), browser.resume() else { socket.close(); return }
            for previous in Array(connections.values) where previous.browser === browser { previous.close() }
            // Replacement is not active until acknowledged native teardown.
            // Quarantine is fail-closed; it never resets a sibling controller.
            for _ in 0..<300 {
                if connections.values.contains(where: { $0.browser === browser && $0.cleanupFailed }) { socket.close(); return }
                if !connections.values.contains(where: { $0.browser === browser }) { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled, !connections.values.contains(where: { $0.browser === browser }),
                  store.browser(for: key) === browser,
                  MachineBrowserService.shared.resolve(route)?.terminalID == resolved.terminalID,
                  authorized(route) else { socket.close(); return }
            let connection = PaneCDPConnection(browser: browser, store: store, socket: socket,
                authorized: { [weak self] in self?.authorized(route) == true }, transformUploadPaths: { [weak self] key, paths in
                    if let transform = self?.transformUploadPaths { return try await transform(key, paths) }
                    return paths
                }, downloadDidChange: { [weak self] key, metadata in self?.downloadDidChange?(key, metadata) })
            connections[id] = connection
            connectionRoutes[id] = route
            connection.didBeginClose = { [weak self] in self?.updateActivity() }
            connection.didClose = { [weak self] in self?.connections[id] = nil; self?.connectionRoutes[id] = nil; self?.updateActivity() }
            updateActivity()
            for message in waitingSockets[id]?.messages ?? [] { connection.receive(message) }
        }
        waitingSockets[id] = WaitingSocket(route: route, socket: socket, messages: [text], task: task)
    }

    func invalidate(_ browser: PaneBrowser) {
        for connection in Array(connections.values) where connection.browser === browser { connection.close() }
    }

    private func updateActivity() {
        activeConnections = connections.values.filter { !$0.isClosed }.count
        // Retiring/quarantined leases still hold App Nap and suspend exclusion,
        // but are not live agent sockets (including for quit confirmation).
        if !connections.isEmpty, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                            reason: "Pane browser agent connection")
        } else if connections.isEmpty, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func closeConnections() {
        acceptingConnections = false
        for pending in waitingSockets.values { pending.task.cancel() }
        waitingSockets = [:]
        for connection in Array(connections.values) { connection.close() }
        updateActivity()
    }
    func engineDidStop() {
        precondition(!BrowserEngine.isRunning)
        for connection in Array(connections.values) { connection.engineDidStop() }
        updateActivity()
    }
    func stop() async {
        closeConnections()
        await listener?.stop()
        listener = nil
        port = nil
        token = ""
    }
}

nonisolated struct ProxyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One authenticated agent owns explicitly detached native page sessions. Browser-level
/// auto-attach is virtual: we NEVER ask CEF to pause/attach all its targets.
@MainActor
final class PaneCDPConnection {
    let browser: PaneBrowser
    private let store: BrowserStore
    private let socket: CDPWebSocket
    private let transformUploadPaths: BrowserUploadPathTransform
    private let authorized: () -> Bool
    private let downloadDidChange: BrowserDownloadObserver
    private var native: NativeCDPTransport?
    private var nativeOwner: NativeCDPTransport.Owner?
    private var pollTask: Task<Void, Never>?
    private var startup: Task<Void, Error>?
    private var clientIDs = Set<Int>()
    private var targets: [String: [String: Any]] = [:]
    private var sessions: [String: String] = [:]
    private let pageSessions = CDPPageSessionState()
    private var parents: [String: String] = [:]
    private var streams = Set<String>()
    private var downloadsAllowed = true
    private var downloadEvents = false
    private var discovering = false
    private var refreshing = false
    private var retiringPageSessions = Set<String>()
    private(set) var isClosed = false
    private var didFinishClose = false
    var cleanupFailed: Bool { nativeOwner?.state == .quarantined || native?.failed == true }
    var isQuiescent: Bool { !isClosed && !cleanupFailed && nativeOwner != nil && clientIDs.isEmpty && !refreshing && retiringPageSessions.isEmpty }
    #if DEBUG
    private(set) var observedChildTargetTypes = Set<String>()
    #endif
    var didBeginClose: (() -> Void)?
    var didClose: (() -> Void)?

    init(browser: PaneBrowser, store: BrowserStore, socket: CDPWebSocket,
         authorized: @escaping () -> Bool,
         transformUploadPaths: @escaping BrowserUploadPathTransform,
         downloadDidChange: @escaping BrowserDownloadObserver) {
        self.transformUploadPaths = transformUploadPaths
        self.authorized = authorized
        self.downloadDidChange = downloadDidChange
        self.browser = browser
        self.store = store
        self.socket = socket
        browser.agentConnected = true
        browser.agentSocketConnected = true
        browser.agentDownloadChanged = { [weak self] metadata in
            guard let self else { return }
            self.downloadDidChange(self.browser.key, metadata)
            guard self.downloadEvents, let method = metadata["event"] as? String else { return }
            var params = metadata
            params["event"] = nil
            self.event(method, params)
        }
        configurePages()
        startup = Task {
            do { try await connect() }
            catch {
                close()
                if native == nil { finishClose() }
                throw error
            }
        }
    }

    private func configurePages() {
        let folder = store.downloadFolder(for: browser)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for tab in browser.tabs {
            tab.page?.agentControlled = true
            tab.page?.agentDownloadsAllowed = downloadsAllowed
            tab.page?.agentDownloadFolder = folder.path
        }
    }

    private func connect() async throws {
        try Task.checkCancellation()
        let (transport, owner) = try await NativeCDPController.shared.acquire()
        native = transport; nativeOwner = owner
        owner.failed = { [weak self] in self?.close() }
        owner.events = { [weak self] message in self?.receiveNativeEvent(message) }
        guard !isClosed, authorized() else {
            if isClosed { transport.retire(owner) { [weak self] in self?.finishClose() } }
            else { close() }
            throw ProxyError("Connection closed during acquisition.")
        }
        for _ in 0..<200 {
            if !browser.tabs.compactMap(\.cdpTargetID).isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await refreshTargets()
        pollTask = Task {
            while !isClosed {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                do { try await refreshTargets() } catch { close() }
            }
        }
    }

    func receive(_ text: String) {
        guard !isClosed, text.utf8.count <= CDPPolicy.maximumMessageBytes,
              let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = message["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue),
              let method = message["method"] as? String,
              message["params"] == nil || message["params"] is [String: Any],
              message["sessionId"] == nil || message["sessionId"] is String,
              clientIDs.count < 256, clientIDs.insert(number.intValue).inserted else { close(); return }
        let id = number.intValue
        let session = message["sessionId"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        Task {
            defer { clientIDs.remove(id) }
            do {
                try await startup?.value
                guard !isClosed else { return }
                let result = try await handle(method, params: params, session: session)
                if let session, sessions[session] == nil { throw ProxyError("Session retired during command.") }
                var reply: [String: Any] = ["id": id, "result": result]
                if let session { reply["sessionId"] = session }
                send(reply)
            } catch {
                var reply: [String: Any] = ["id": id, "error": ["code": -32000, "message": "Pane command rejected or failed."]]
                if let session { reply["sessionId"] = session }
                send(reply)
            }
        }
    }

    private func handle(_ method: String, params: [String: Any], session: String?) async throws -> [String: Any] {
        guard !isClosed, authorized() else { close(); throw ProxyError("Pane authority retired.") }
        if let context = params["browserContextId"] as? String,
           !targets.values.contains(where: { $0["browserContextId"] as? String == context }) { throw ProxyError("Foreign context.") }
        if let session {
            guard sessions[session] != nil else { throw ProxyError("Foreign session.") }
            if method == "Target.setAutoAttach" {
                guard params["flatten"] as? Bool == true else { throw ProxyError("Only flat sessions supported.") }
                return try await call(method, params: params, session: session)
            }
            guard CDPPolicy.pageMethods.contains(method) else { throw ProxyError("Page command not allowed.") }
            if method == "Page.handleJavaScriptDialog" {
                var root = session
                while let parent = parents[root] { root = parent }
                guard let target = sessions[root], let tab = browser.tabs.first(where: { $0.cdpTargetID == target }),
                      let accept = params["accept"] as? Bool else { throw ProxyError("Unknown dialog owner.") }
                let text = params["promptText"] as? String ?? ""
                if tab.page?.handleAgentDialog(accept: accept, text: text) == true { return [:] }
                if let prompt = tab.prompts.first(where: { if case .dialog = $0.kind { return true }; return false }) {
                    prompt.answer(accept ? .accept(text: text) : .decline)
                    return [:]
                }
                throw ProxyError("No dialog is pending.")
            }
            if method == "IO.read" || method == "IO.close" {
                guard let handle = params["handle"] as? String, streams.contains(handle) else { throw ProxyError("Foreign stream.") }
            }
            if method == "Page.navigate" || method == "Fetch.continueRequest", let url = params["url"] as? String,
               !CDPPolicy.navigationAllowed(url) { throw ProxyError("Unsafe navigation.") }
            if method == "Page.navigate", params["url"] as? String == nil { throw ProxyError("Missing URL.") }
            var forwarded = params
            if method == "DOM.setFileInputFiles" {
                guard let files = params["files"] as? [String] else { throw ProxyError("Invalid upload paths.") }
                forwarded["files"] = try await transformUploadPaths(browser.key, files)
            }
            let result = try await call(method, params: forwarded, session: session)
            if method == "IO.close", let handle = params["handle"] as? String { streams.remove(handle) }
            if let stream = result["stream"] as? String { streams.insert(stream) }
            return result
        }
        switch method {
        case "Browser.getVersion": return try await call(method)
        case "Target.getBrowserContexts": return ["browserContextIds": []]
        case "Target.getTargets": try await refreshTargets(); return ["targetInfos": Array(targets.values)]
        case "Target.getTargetInfo":
            if params["targetId"] == nil {
                // Playwright uses the argument-free browser target query as
                // an auto-attach barrier. Never disclose CEF's global target.
                return ["targetInfo": ["targetId": "pane-browser-" + browser.downloadID,
                                       "type": "browser", "title": "", "url": "", "attached": true]]
            }
            guard let id = params["targetId"] as? String, let info = targets[id] else { throw ProxyError("Foreign target.") }
            return ["targetInfo": info]
        case "Target.setDiscoverTargets":
            discovering = params["discover"] as? Bool == true
            if discovering { for info in targets.values { event("Target.targetCreated", ["targetInfo": info]) } }
            return [:]
        case "Target.setAutoAttach":
            guard params["flatten"] as? Bool == true else { throw ProxyError("Only flat sessions supported.") }
            let enabled = params["autoAttach"] as? Bool == true
            // Invalidate acquisitions and public routing immediately, even if a
            // preceding enable is still awaiting its native attach response.
            let epoch = pageSessions.setAutoAttach(enabled)
            if !enabled {
                for session in pageSessions.retiringAutomatic { forgetSession(session) }
            }
            while pageSessions.changing {
                try await Task.sleep(for: .milliseconds(10))
                guard !isClosed else { throw ProxyError("Connection closed.") }
            }
            pageSessions.changing = true
            defer { pageSessions.changing = false }
            // Old successful acquisitions compensate themselves before removing
            // their acquisition entry. Never acknowledge disable before that.
            while pageSessions.hasAutomaticAcquisition {
                try await Task.sleep(for: .milliseconds(10))
                guard !isClosed else { throw ProxyError("Connection closed.") }
            }
            for session in Array(pageSessions.retiringAutomatic) {
                try await retirePageSession(session, notify: true)
            }
            if enabled, pageSessions.epoch == epoch {
                for target in Array(targets.keys) {
                    _ = try await attach(target, kind: .automatic, epoch: epoch)
                }
            }
            return [:]
        case "Target.attachToTarget":
            guard let target = params["targetId"] as? String, targets[target] != nil, params["flatten"] as? Bool == true,
                  let session = try await attach(target, kind: .manual) else { throw ProxyError("Foreign target.") }
            return ["sessionId": session]
        case "Target.detachFromTarget":
            guard let session = params["sessionId"] as? String, sessions[session] != nil else { throw ProxyError("Foreign session.") }
            try await retirePageSession(session, notify: false)
            return [:]
        case "Target.createTarget":
            let url = params["url"] as? String ?? "about:blank"
            guard CDPPolicy.navigationAllowed(url) else { throw ProxyError("Unsafe navigation.") }
            let tab = browser.openTab(url: url)
            guard browser.resume() else { throw ProxyError("Browser could not resume for the new tab.") }
            configurePages()
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(50))
                try await refreshTargets()
                if let id = tab.cdpTargetID, targets[id] != nil { return ["targetId": id] }
                if isClosed { throw ProxyError("Connection closed.") }
            }
            throw ProxyError("Tab did not become ready.")
        case "Target.closeTarget":
            guard let id = params["targetId"] as? String, targets[id] != nil,
                  let tab = browser.tabs.first(where: { $0.cdpTargetID == id }) else { throw ProxyError("Foreign target.") }
            browser.close(tab)
            return ["success": true]
        case "Browser.setDownloadBehavior":
            guard ["allow", "allowAndName", "default", "deny"].contains(params["behavior"] as? String ?? "") else {
                throw ProxyError("Unknown download behavior.")
            }
            // CEF owns download paths and quarantine. Never accept an agent's
            // arbitrary Mac path, nor change Chromium's process-wide default.
            downloadsAllowed = params["behavior"] as? String != "deny"
            downloadEvents = params["eventsEnabled"] as? Bool == true
            configurePages()
            return [:]
        case "Storage.getCookies", "Storage.setCookies", "Storage.clearCookies":
            guard let target = targets.keys.sorted().first else { throw ProxyError("No page.") }
            guard let session = try await attach(target, kind: .manual) else { throw ProxyError("No page session.") }
            if method == "Storage.getCookies" { return try await call("Network.getAllCookies", session: session) }
            if method == "Storage.setCookies" {
                return try await call("Network.setCookies", params: ["cookies": params["cookies"] ?? []], session: session)
            }
            let cookies = try await call("Network.getAllCookies", session: session)["cookies"] as? [[String: Any]] ?? []
            for cookie in cookies {
                _ = try await call("Network.deleteCookies", params: ["name": cookie["name"] ?? "",
                    "domain": cookie["domain"] ?? "", "path": cookie["path"] ?? "/"], session: session)
            }
            return [:]
        default: throw ProxyError("Browser command not allowed.")
        }
    }

    @discardableResult
    private func attach(_ target: String, kind: CDPPageSessionState.Kind, epoch requestedEpoch: UInt64? = nil) async throws -> String? {
        let key = CDPPageSessionState.Key(target: target, kind: kind)
        let epoch = requestedEpoch ?? pageSessions.epoch
        guard !isClosed, targets[target] != nil else { throw ProxyError("Unknown target.") }
        guard pageSessions.canPublish(key, epoch: epoch) else { return nil }
        if let existing = pageSessions.session(for: key) { return existing }
        while pageSessions.acquiring.contains(key) {
            try await Task.sleep(for: .milliseconds(10))
            guard !isClosed else { throw ProxyError("Connection closed.") }
            guard pageSessions.canPublish(key, epoch: epoch) else { return nil }
            if let existing = pageSessions.session(for: key) { return existing }
        }
        pageSessions.acquiring.insert(key)
        defer { pageSessions.acquiring.remove(key) }
        let result = try await call("Target.attachToTarget", params: ["targetId": target, "flatten": true])
        guard let session = result["sessionId"] as? String else { throw ProxyError("Attach failed.") }
        guard !isClosed, let info = targets[target], pageSessions.canPublish(key, epoch: epoch) else {
            if !isClosed { _ = try await call("Target.detachFromTarget", params: ["sessionId": session]) }
            return nil
        }
        sessions[session] = target
        pageSessions.record(session, for: key)
        if kind == .automatic {
            event("Target.attachedToTarget", ["sessionId": session, "targetInfo": info, "waitingForDebugger": false])
        }
        return session
    }

    private func retirePageSession(_ session: String, notify: Bool) async throws {
        while retiringPageSessions.contains(session) {
            try await Task.sleep(for: .milliseconds(10))
            guard !isClosed else { throw ProxyError("Connection closed.") }
        }
        guard pageSessions.contains(session) || sessions[session] != nil else { return }
        retiringPageSessions.insert(session)
        defer { retiringPageSessions.remove(session) }
        let target = sessions[session] ?? targets.keys.first { pageSessions.sessions(for: $0).contains(session) }
        // Remove public routes before awaiting native teardown. Failed detach
        // keeps the native owner quarantined; success alone clears acquisition state.
        forgetSession(session)
        _ = try await call("Target.detachFromTarget", params: ["sessionId": session])
        pageSessions.remove(session)
        if notify {
            var params: [String: Any] = ["sessionId": session]
            if let target { params["targetId"] = target }
            event("Target.detachedFromTarget", params)
        }
    }

    private func refreshTargets() async throws {
        while refreshing {
            try await Task.sleep(for: .milliseconds(10))
            guard !isClosed else { return }
        }
        guard !isClosed else { return }
        refreshing = true
        defer { refreshing = false }
        configurePages()
        let ids = Set(browser.tabs.compactMap(\.cdpTargetID))
        let all = try await call("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        var fresh: [String: [String: Any]] = [:]
        for info in all {
            guard let id = info["targetId"] as? String, ids.contains(id), info["type"] as? String == "page",
                  let url = info["url"] as? String, CDPPolicy.navigationAllowed(url) else { continue }
            fresh[id] = info
        }
        for (id, info) in fresh where targets[id] == nil {
            targets[id] = info
            if discovering { event("Target.targetCreated", ["targetInfo": info]) }
        }
        for id in Array(targets.keys) where fresh[id] == nil {
            targets[id] = nil
            for session in pageSessions.sessions(for: id) {
                try await retirePageSession(session, notify: true)
            }
            if discovering { event("Target.targetDestroyed", ["targetId": id]) }
        }
        for (id, info) in fresh {
            if let old = targets[id], !NSDictionary(dictionary: old).isEqual(to: info), discovering {
                event("Target.targetInfoChanged", ["targetInfo": info])
            }
            targets[id] = info
        }
        if pageSessions.autoAttach, !pageSessions.changing {
            let epoch = pageSessions.epoch
            for target in Array(targets.keys) {
                _ = try await attach(target, kind: .automatic, epoch: epoch)
            }
        }
    }

    private func call(_ method: String, params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        guard !isClosed, authorized(), let native, let nativeOwner else { close(); throw ProxyError("Native connection closed") }
        return try await native.call(nativeOwner, method, params: params, session: session)
    }

    private func receiveNativeEvent(_ message: [String: Any]) {
        guard !isClosed, authorized() else { close(); return }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let parent = message["sessionId"] as? String {
            guard sessions[parent] != nil else { return }
            if method == "Target.attachedToTarget" {
                guard let child = params["sessionId"] as? String,
                      let info = params["targetInfo"] as? [String: Any], let id = info["targetId"] as? String else { return }
                if ["iframe", "worker"].contains(info["type"] as? String ?? "") {
                    sessions[child] = id
                    parents[child] = parent
                    #if DEBUG
                    observedChildTargetTypes.insert(info["type"] as! String)
                    #endif
                } else {
                    // Shared/service workers have no exclusive pane owner.
                    // Release a debugger wait before detaching, never freeze it.
                    Task {
                        do {
                            _ = try await call("Runtime.runIfWaitingForDebugger", session: child)
                            _ = try await call("Target.detachFromTarget", params: ["sessionId": child], session: parent)
                        } catch { close() }
                    }
                    return
                }
            } else if method == "Target.detachedFromTarget", let child = params["sessionId"] as? String {
                guard sessions[child] != nil else { return }
                forgetSession(child)
            }
            send(message)
        }
        // Browser-root events are not forwarded. Discovery is synthesized
        // from CEF-owned pages; no foreign target IDs/context metadata leak.
    }

    private func forgetSession(_ id: String) {
        for child in Array(parents.keys) where parents[child] == id { forgetSession(child) }
        parents[id] = nil
        sessions[id] = nil
    }

    private func event(_ method: String, _ params: [String: Any]) { send(["method": method, "params": params]) }
    private func send(_ message: [String: Any]) {
        guard !isClosed, authorized() else { close(); return }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(String(decoding: data, as: UTF8.self))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        browser.agentSocketConnected = false
        didBeginClose?()
        startup?.cancel(); pollTask?.cancel()
        socket.close()
        // Keep request guards, suspend exclusion and App Nap until native
        // acquisitions and detach acknowledgements establish successful teardown.
        if let native, let nativeOwner {
            native.retire(nativeOwner) { [weak self] in self?.finishClose() }
        } else if startup == nil { finishClose() }
        // If acquisition is in flight it retires itself when it resumes.
    }

    func engineDidStop() {
        precondition(!BrowserEngine.isRunning)
        finishClose()
    }

    private func finishClose() {
        // Late startup errors/engine-stop callbacks must not reset a replacement.
        guard !didFinishClose else { return }
        didFinishClose = true
        native = nil; nativeOwner = nil
        browser.agentConnected = false
        browser.agentDownloadChanged = nil
        for tab in browser.tabs { tab.page?.agentControlled = false; tab.page?.agentDownloadFolder = nil }
        didClose?()
    }
}
#endif
