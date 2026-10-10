#if os(macOS)
import Foundation

/// No discovery HTTP endpoint: the only public resource is an authenticated,
/// pane-scoped WebSocket. Decode exactly once; never accept a query token.
nonisolated struct CDPRoute: Equatable, Sendable {
    let session: String
    let pane: String
    let leaseID: String?

    init?(_ path: String) {
        guard !path.contains("?"), !path.contains("#") else { return nil }
        var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { return nil }
        parts.removeFirst()
        if parts.first == "v1" { parts.removeFirst() }
        var lease: String?
        if parts.count == 6 {
            guard parts[4] == "lease", let id = UUID(uuidString: parts[5]), id.uuidString.lowercased() == parts[5] else { return nil }
            lease = parts[5]; parts.removeLast(2)
        }
        guard parts.count == 4, parts[0] == "herdr", parts[2] == "pane",
              let session = parts[1].removingPercentEncoding,
              let pane = parts[3].removingPercentEncoding,
              Self.valid(session), Self.valid(pane) else { return nil }
        self.session = session
        self.pane = pane
        self.leaseID = lease
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\") && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    var versionedPath: String { basePath + (leaseID.map { "/lease/" + $0 } ?? "") }

    var basePath: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:~"))
        return "/v1/herdr/\(session.addingPercentEncoding(withAllowedCharacters: allowed)!)/pane/\(pane.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }
}

nonisolated enum CDPPolicy {
    static let maximumMessageBytes = 16 * 1024 * 1024

    static func authenticated(_ headers: [String], token: String) -> Bool {
        guard headers.count == 1 else { return false }
        let supplied = Array(headers[0].utf8), expected = Array("Bearer \(token)".utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func navigationAllowed(_ text: String) -> Bool {
        guard let url = URLComponents(string: text), let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about", url.path == "blank", url.host == nil, url.query == nil { return true }
        return ["http", "https", "data", "blob"].contains(scheme)
    }

    /// Page sessions are scoped, but numerous commands still affect the
    /// process, profile, filesystem, or security policy. Explicitly enumerate
    /// only the methods used for normal Playwright page automation.
    static let pageMethods: Set<String> = [
        "Page.enable", "Page.disable", "Page.getFrameTree", "Page.navigate", "Page.reload", "Page.stopLoading",
        "Page.getNavigationHistory", "Page.navigateToHistoryEntry", "Page.addScriptToEvaluateOnNewDocument",
        "Page.removeScriptToEvaluateOnNewDocument", "Page.createIsolatedWorld", "Page.handleJavaScriptDialog",
        "Page.captureScreenshot", "Page.getLayoutMetrics", "Page.setLifecycleEventsEnabled", "Page.bringToFront",
        "Page.setInterceptFileChooserDialog", "Page.close", "Page.setWebLifecycleState",
        "Runtime.enable", "Runtime.disable", "Runtime.evaluate", "Runtime.callFunctionOn", "Runtime.getProperties",
        "Runtime.releaseObject", "Runtime.releaseObjectGroup", "Runtime.runIfWaitingForDebugger", "Runtime.addBinding",
        "Runtime.removeBinding", "Runtime.discardConsoleEntries",
        "DOM.enable", "DOM.disable", "DOM.getDocument", "DOM.describeNode", "DOM.resolveNode", "DOM.getBoxModel",
        "DOM.getContentQuads", "DOM.scrollIntoViewIfNeeded", "DOM.setFileInputFiles", "DOM.getNodeForLocation",
        "DOM.querySelector", "DOM.querySelectorAll", "DOM.focus", "DOM.getOuterHTML",
        "CSS.enable", "CSS.getComputedStyleForNode",
        "Network.enable", "Network.disable", "Network.getCookies", "Network.getAllCookies", "Network.setCookies",
        "Network.setCookie", "Network.deleteCookies", "Network.getResponseBody", "Network.setExtraHTTPHeaders",
        "Network.setCacheDisabled", "Network.setUserAgentOverride", "Network.emulateNetworkConditions",
        "Network.setBypassServiceWorker",
        "Fetch.enable", "Fetch.disable", "Fetch.continueRequest", "Fetch.continueResponse", "Fetch.fulfillRequest",
        "Fetch.failRequest", "Fetch.continueWithAuth", "Fetch.getResponseBody", "Fetch.takeResponseBodyAsStream",
        "Input.dispatchMouseEvent", "Input.dispatchKeyEvent", "Input.insertText", "Input.dispatchTouchEvent",
        "Input.synthesizeTapGesture", "Input.synthesizeScrollGesture", "Input.synthesizePinchGesture",
        "Emulation.setFocusEmulationEnabled", "Emulation.setEmulatedMedia", "Emulation.setScriptExecutionDisabled",
        "Emulation.setTouchEmulationEnabled", "Emulation.setDefaultBackgroundColorOverride",
        "Emulation.setLocaleOverride", "Emulation.setTimezoneOverride", "Emulation.setGeolocationOverride",
        "Emulation.setAutomationOverride", "Emulation.setUserAgentOverride",
        "Log.enable", "Log.disable", "Log.clear", "Performance.enable", "Performance.getMetrics",
        "Accessibility.enable", "Accessibility.getFullAXTree", "Accessibility.getPartialAXTree",
        "Debugger.enable", "Debugger.disable", "Debugger.setAsyncCallStackDepth", "Debugger.setBlackboxPatterns",
        "IO.read", "IO.close"
    ]
}
#endif
