#if os(macOS)
import AppKit
import Observation
import OSLog

/// A place in a window where a pane browser can be shown — one per window
/// that shows the browser column. It wants to show one pane's browser at a
/// time (`key`); which region actually shows a browser wanted by two of them
/// is `BrowserStore`'s call.
@MainActor
final class BrowserRegion {
    let id = UUID()
    let container: NSView = {
        let view = NSView()
        view.autoresizesSubviews = true
        return view
    }()
    fileprivate(set) var key: BrowserKey?
}

/// Every pane browser in the app, and where each one is on screen.
///
/// One for the whole app, because a pane browser belongs to its pane and not
/// to a window (A1, A4): a browser keeps running whichever pane, window or
/// machine is on screen, until its pane is gone (F3–F5) or the app quits
/// (F8). It also keeps `browsers.json`, from which the browsers come back at
/// the next launch and by which the profile folders of panes that are gone
/// get deleted (F11).
@MainActor
@Observable
final class BrowserStore {
    static let shared = BrowserStore()

    private(set) var browsers: [BrowserKey: PaneBrowser] = [:]
    /// Why the browser engine couldn't be started, if it couldn't.
    private(set) var engineError: String?
    /// For each pane browser on screen, the region showing it: the region of
    /// the window it was last chosen in (decision 3).
    private(set) var presenters: [BrowserKey: UUID] = [:]

    /// How many pane browsers may have their pages open at once (A7).
    /// Beyond that, the ones longest off screen are suspended.
    static let maximumRunningBrowsers = 6

    #if DEBUG
    /// The made-up Machine of `BrowserSelfTest`, whose browsers
    /// `reconcile(machines:)` leaves alone.
    @ObservationIgnored var machineIgnoredByReconcile: UUID?
    #endif

    @ObservationIgnored private(set) var aliases: [BrowserKey: BrowserAlias] = [:]
    @ObservationIgnored private var regions: [UUID: WeakRegion] = [:]
    @ObservationIgnored private var profiles: [ProfileChoice: BrowserProfile] = [:]
    @ObservationIgnored private var foldersToDelete: [String] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.bldg-7.shepherd", category: "Browser")

    /// Everything the browser keeps on disk: CEF's root folder, the profiles
    /// in it, and `browsers.json`. A development build keeps its own,
    /// because CEF won't let two running apps share one.
    ///
    /// Every profile's folder is right inside it: Chromium can't create a
    /// profile anywhere deeper, and falls back to one kept in memory only.
    let rootFolder: URL
    private var indexFile: URL { rootFolder.appending(path: "browsers.json") }

    /// A profile's folder, by `ProfileChoice.folderName`.
    func profileFolder(named name: String) -> URL {
        rootFolder.appending(path: name, directoryHint: .isDirectory)
    }

    private struct WeakRegion {
        weak var region: BrowserRegion?
    }

    init(rootFolder testRoot: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.bldg-7.shepherd"
        #if DEBUG
        let folderName = "Browser-Debug"
        #else
        let folderName = "Browser"
        #endif
        #if DEBUG
        let environmentRoot = ProcessInfo.processInfo.environment["SHEPHERD_BROWSER_TEST_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let environmentRoot: URL? = nil
        #endif
        // CEF canonicalizes root_cache_path but not request-context paths.
        // Resolve /tmp -> /private/tmp (and user symlinks) once for both,
        // or Chromium silently falls back to memory-only profiles.
        let root = (testRoot ?? environmentRoot ?? support.appending(path: bundleID).appending(path: folderName, directoryHint: .isDirectory)).resolvingSymlinksInPath()
        if let physicalPath = realpath(root.path, nil) {
            rootFolder = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
            free(physicalPath)
        } else {
            rootFolder = root
        }
        loadIndex()
    }

    // MARK: Browsers

    /// The pane's browser, if it has one with any tabs.
    func browser(for key: BrowserKey) -> PaneBrowser? {
        guard let key = canonicalKey(for: key), let browser = browsers[key], !browser.tabs.isEmpty else { return nil }
        return browser
    }

    func canonicalKey(for key: BrowserKey) -> BrowserKey? {
        if let alias = aliases[key] {
            guard let browser = browsers[alias.current], browser.terminalID == alias.terminalID else { return nil }
            return alias.current
        }
        return key
    }

    func downloadFolder(for browser: PaneBrowser) -> URL {
        // Stable terminal identity, not a pane ID or agent-provided path,
        // owns downloads even after a move. Shared profiles still get a
        // separate download directory per pane.
        let identity = browser.downloadID
        return rootFolder.appending(path: "AgentDownloads", directoryHint: .isDirectory).appending(path: identity)
    }

    func hasBrowser(for key: BrowserKey) -> Bool {
        browser(for: key) != nil
    }

    /// Opens a browser for the pane, or a new tab in the one it has (A3,
    /// B7: any pane can have one, with or without an agent).
    func openBrowser(for key: BrowserKey, terminalID: String, url: String = "about:blank") {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        let browser: PaneBrowser
        if let existing = browsers[key], existing.terminalID == terminalID {
            browser = existing
        } else {
            if let stale = browsers[key] {
                discard(stale)
            }
            browser = PaneBrowser(key: key, terminalID: terminalID, profile: .newIsolated(), store: self)
            browsers[key] = browser
        }
        browser.lastShown = .now
        browser.openTab(url: url)
        if browser.isSuspended {
            browser.resume()
        }
        suspendIdleBrowsers()
        browserDidChange(browser)
    }

    /// Closes the pane's browser: its pages and tabs, but not its profile,
    /// which a browser opened for the pane later uses again.
    func closeBrowser(for key: BrowserKey) {
        browsers[key]?.closeAllTabs()
    }

    /// Something about a browser changed that `browsers.json` and the screen
    /// should reflect.
    func browserDidChange(_ browser: PaneBrowser, layout shouldLayout: Bool = true) {
        if shouldLayout {
            layout()
        }
        scheduleSave()
    }

    /// Gets rid of a pane browser for good: its pages, its record, and its
    /// profile if that was the pane's own (F3, F11).
    private func discard(_ browser: PaneBrowser) {
        CDPProxy.shared.invalidate(browser)
        aliases = aliases.filter { $0.value.current != browser.key }
        try? FileManager.default.removeItem(at: downloadFolder(for: browser))
        browser.suspend()
        browsers[browser.key] = nil
        presenters[browser.key] = nil
        if let folder = browser.profile.isolatedFolder {
            discardProfileFolder(folder)
        }
        scheduleSave()
    }

    // MARK: Following herdr

    /// Brings the browsers of one herdr in line with the panes it has now —
    /// all of them, as a snapshot lists them. The browser of a pane that is
    /// gone is closed and its profile deleted: the pane was closed, or its
    /// tab or workspace was (F3, F4). So is the browser of a pane whose ID
    /// now names another terminal: herdr was restarted and numbered its
    /// panes from the start again (B3, F5).
    func reconcile(machineID: UUID, herdrMachineID: String?, panes: [AgentSummary]) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        let terminals = Dictionary(panes.map { ($0.paneID, $0.terminalID) }, uniquingKeysWith: { first, _ in first })
        let byTerminal = Dictionary(grouping: panes, by: \.terminalID)
        for browser in Array(browsers.values) where browser.key.isOn(machineID: machineID, herdrMachineID: herdrMachineID) {
            let oldKey = browser.key
            if terminals[oldKey.paneID] == browser.terminalID { continue }
            if let matches = byTerminal[browser.terminalID], matches.count == 1, let pane = matches.first {
                let newKey = oldKey.replacingPaneID(pane.paneID)
                if let stale = browsers[newKey], stale !== browser { discard(stale) }
                browsers[oldKey] = nil
                browser.remap(to: newKey)
                browsers[newKey] = browser
                for (key, alias) in aliases where alias.current == oldKey {
                    aliases[key] = BrowserAlias(previous: key, current: newKey, terminalID: browser.terminalID)
                }
                if terminals[oldKey.paneID] == nil {
                    aliases[oldKey] = BrowserAlias(previous: oldKey, current: newKey, terminalID: browser.terminalID)
                }
                if let previous = pane.previousPaneID {
                    let key = oldKey.replacingPaneID(previous)
                    if terminals[previous] == nil { aliases[key] = BrowserAlias(previous: key, current: newKey, terminalID: browser.terminalID) }
                }
                presenters[newKey] = presenters.removeValue(forKey: oldKey)
                for region in regions.values.compactMap(\.region) where region.key == oldKey { region.key = newKey }
                scheduleSave()
            } else {
                discard(browser)
            }
        }
        // A reused ID is never a usable alias to a different terminal.
        aliases = aliases.filter { key, alias in
            !key.isOn(machineID: machineID, herdrMachineID: herdrMachineID) ||
                terminals[key.paneID] == nil || terminals[key.paneID] == alias.terminalID
        }
        layout()
    }

    /// Brings the browsers on a Machine's herdr machines in line with the
    /// herdr machines saved on its host now: one that was removed from herdr
    /// takes its browsers with it.
    func reconcile(machineID: UUID, herdrMachines: Set<String>) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        for browser in Array(browsers.values) where browser.key.machineID == machineID {
            if let herdrMachineID = browser.key.herdrMachineID, !herdrMachines.contains(herdrMachineID) {
                discard(browser)
            }
        }
        layout()
    }

    /// Brings the browsers in line with the Shepherd Machines there are: a
    /// Machine that was removed takes its browsers with it, and so does a
    /// change of the herdr session it uses, since its panes are another
    /// session's then.
    func reconcile(machines: [Machine]) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        #if DEBUG
        let ignored = machineIgnoredByReconcile
        #else
        let ignored: UUID? = nil
        #endif
        let sessions = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, BrowserKey.session(named: $0.sessionName)) })
        for browser in Array(browsers.values) where browser.key.machineID != ignored {
            guard let session = sessions[browser.key.machineID] else {
                discard(browser)
                continue
            }
            if browser.key.herdrMachineID == nil, browser.key.session != session {
                discard(browser)
            }
        }
        layout()
    }

    // MARK: On screen

    /// The region now wants to show the browser of `key`'s pane, or none.
    /// The browser goes to the region most recently pointed at it.
    func show(_ key: BrowserKey?, in region: BrowserRegion, terminalID: String?) {
        regions[region.id] = WeakRegion(region: region)
        guard region.key != key else { return }
        let previous = region.key
        region.key = key
        if let previous, presenters[previous] == region.id {
            presenters[previous] = otherRegion(wanting: previous, besides: region)
        }
        if let key {
            presenters[key] = region.id
            prepareToShow(key, terminalID: terminalID)
        }
        layout()
    }

    /// Has the region show its pane's browser, which another window is
    /// showing ("Show Here").
    func bringBrowser(to region: BrowserRegion) {
        guard let key = region.key else { return }
        presenters[key] = region.id
        layout()
    }

    /// The region's window went away, or no longer shows the browser
    /// column. Its browser goes to another window that wants it, or back to
    /// the holder window, where it keeps running (A5).
    func remove(_ region: BrowserRegion) {
        regions[region.id] = nil
        if let key = region.key, presenters[key] == region.id {
            presenters[key] = otherRegion(wanting: key, besides: region)
        }
        region.key = nil
        layout()
    }

    func isShown(_ key: BrowserKey, in region: BrowserRegion) -> Bool {
        presenters[key] == region.id
    }

    private func otherRegion(wanting key: BrowserKey, besides region: BrowserRegion) -> UUID? {
        regions.values.compactMap(\.region).first { $0 !== region && $0.key == key }?.id
    }

    /// Before a pane browser goes on screen: one that belongs to an earlier
    /// pane with the same ID is let go of, and a suspended one opens its
    /// pages again.
    private func prepareToShow(_ key: BrowserKey, terminalID: String?) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        guard let browser = browsers[key] else { return }
        if let terminalID, browser.terminalID != terminalID {
            discard(browser)
            return
        }
        browser.lastShown = .now
        if browser.isSuspended, !browser.tabs.isEmpty {
            browser.resume()
            suspendIdleBrowsers()
        }
    }

    /// Puts every page's view where it belongs: the selected tab of a browser
    /// on screen in its region, everything else in the holder window.
    func layout() {
        for browser in browsers.values {
            let region = presenters[browser.key].flatMap { regions[$0]?.region }
            let selected = browser.selectedTab
            for tab in browser.tabs {
                guard let view = tab.page?.view else { continue }
                if let region, tab === selected {
                    let container = region.container
                    if view.superview !== container {
                        view.removeFromSuperview()
                        container.addSubview(view)
                    }
                    if view.frame != container.bounds {
                        view.frame = container.bounds
                    }
                } else if view.superview !== holderView {
                    // At the size it had, so that a page an agent works in
                    // off screen is laid out as it was when last seen.
                    view.removeFromSuperview()
                    view.setFrameOrigin(.zero)
                    holderView.addSubview(view)
                }
            }
        }
    }

    /// Where the views of pages that aren't on screen are: a window that is
    /// never shown (A17). A page in it keeps running and rendering, as one
    /// that is merely hidden would not (phase 0, S3).
    @ObservationIgnored private(set) lazy var holderView: NSView = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2560, height: 1600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window.contentView!
    }()

    /// Suspends the browsers off screen for longest, so that no more than
    /// `maximumRunningBrowsers` have their pages open (A7).
    private func suspendIdleBrowsers() {
        let running = browsers.values.filter { !$0.isSuspended }
        let excess = running.count - Self.maximumRunningBrowsers
        guard excess > 0 else { return }
        let candidates = running
            .filter { presenters[$0.key] == nil && !$0.agentConnected }
            .sorted { $0.lastShown < $1.lastShown }
        for browser in candidates.prefix(excess) {
            browser.suspend()
        }
    }

    // MARK: Engine and profiles

    /// The CEF profile for a choice, starting the engine first if this is
    /// the first page of the launch. Nil if the engine couldn't start.
    func profile(for choice: ProfileChoice) -> BrowserProfile? {
        guard startEngine() else { return nil }
        if let profile = profiles[choice] {
            return profile
        }
        let profile = BrowserProfile(folder: profileFolder(named: choice.folderName).path(percentEncoded: false))
        profiles[choice] = profile
        return profile
    }

    private func startEngine() -> Bool {
        guard ShepherdBrowserFeature.shared.isEnabled else { return false }
        if BrowserEngine.isRunning { return true }
        guard BrowserEngine.isAvailable else {
            engineError = String(localized: "The browser needs a Mac with Apple silicon.")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: rootFolder, withIntermediateDirectories: true)
            try BrowserEngine.start(withRootCachePath: rootFolder.path(percentEncoded: false))
            engineError = nil
            return true
        } catch {
            // The engine's own messages are English only.
            engineError = switch (error as? BrowserEngineError)?.code {
            case .loadFailed: String(localized: "The browser engine couldn't be loaded.")
            default: String(localized: "The browser engine didn't start. Another copy of Shepherd may be using the browser.")
            }
            logger.error("The browser engine didn't start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Deletes an isolated profile's folder once nothing uses it any more.
    func discardProfileFolder(_ folder: String) {
        profiles[.isolated(folder: folder)] = nil
        if !foldersToDelete.contains(folder) {
            foldersToDelete.append(folder)
        }
        scheduleSave()
        // The pages that used it are closing as this runs, and CEF lets go
        // of the folder once they have; whatever is still in use by then is
        // deleted at the next launch instead.
        Task {
            try? await Task.sleep(for: .seconds(3))
            deleteDiscardedFolders()
        }
    }

    private func deleteDiscardedFolders() {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        let inUse = Set(browsers.values.compactMap(\.profile.isolatedFolder))
        foldersToDelete.removeAll { folder in
            guard !inUse.contains(folder) else { return true }
            do {
                try FileManager.default.removeItem(at: profileFolder(named: folder))
                return true
            } catch CocoaError.fileNoSuchFile {
                return true
            } catch {
                return false
            }
        }
        scheduleSave()
    }

    /// Closes every page and shuts the engine down, synchronously, for
    /// `applicationShouldTerminate` (F8).
    @discardableResult
    func shutDownNow() -> Bool {
        CDPProxy.shared.closeConnections()
        guard NativeCDPController.shared.prepareForShutdown(within: 5) else {
            engineError = "Browser inspector cleanup could not be confirmed. Quit was canceled; agent access is blocked. Force quit and reopen to recover."
            return false
        }
        saveTask?.cancel()
        // Suspended rather than left to the engine to close: a page closed
        // under its tab takes the tab with it, and the tabs are what the
        // next launch opens again.
        for browser in browsers.values {
            browser.suspend()
        }
        save()
        guard BrowserEngine.isRunning else { return true }
        NativeCDPController.shared.shutDown()
        guard BrowserEngine.shutDown(within: 5) else {
            engineError = "The browser did not finish closing. Quit was canceled to preserve its data; try quitting again."
            return false
        }
        CDPProxy.shared.engineDidStop()
        profiles = [:]
        deleteDiscardedFolders()
        save()
        return true
    }

    /// Keep tabs, profiles and cookies, and leave the initialized CEF engine
    /// resident: same-process shutdown/reinitialization is not supported.
    func suspendForFeatureDisable() {
        precondition(!CDPProxy.shared.hasBrowserWork)
        for browser in browsers.values { browser.suspend() }
        saveTask?.cancel()
        save()
    }

    // MARK: browsers.json

    /// Reads `browsers.json` and makes a suspended pane browser of each
    /// record: they open their pages when their pane is next shown. Also
    /// deletes the profile folders left to delete, and any pane profile
    /// folder that no record names — left behind by an app that didn't get
    /// to quit normally (F9).
    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFile) else { return }
        let index: BrowserIndex
        do {
            index = try JSONDecoder().decode(BrowserIndex.self, from: data)
        } catch {
            logger.error("browsers.json couldn't be read: \(error.localizedDescription, privacy: .public)")
            return
        }
        for record in index.browsers {
            browsers[record.key] = PaneBrowser(
                key: record.key,
                terminalID: record.terminalID,
                profile: record.profile,
                tabURLs: record.tabURLs,
                selectedTab: record.selectedTab,
                store: self
            )
        }
        aliases = Dictionary(index.aliases?.map { ($0.previous, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        foldersToDelete = index.foldersToDelete
        let named = Set(index.browsers.compactMap(\.profile.isolatedFolder))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: rootFolder.path(percentEncoded: false))) ?? []
        for folder in existing where ProfileChoice.isIsolatedFolderName(folder)
            && !named.contains(folder) && !foldersToDelete.contains(folder) {
            foldersToDelete.append(folder)
        }
        deleteDiscardedFolders()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        let index = BrowserIndex(
            browsers: browsers.values.map(\.record).sorted { $0.key.paneID < $1.key.paneID },
            foldersToDelete: foldersToDelete,
            aliases: Array(aliases.values)
        )
        do {
            try FileManager.default.createDirectory(at: rootFolder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(index).write(to: indexFile, options: .atomic)
        } catch {
            logger.error("browsers.json couldn't be written: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
