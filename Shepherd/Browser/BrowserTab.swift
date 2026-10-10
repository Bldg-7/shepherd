#if os(macOS)
import AppKit
import Observation

/// Something a page waits on the person for: a JavaScript dialog, a sign-in
/// a server asks for, or a permission a site asks for (plan items A9, A10).
/// Shown over the page when its tab is on screen; until then the page waits.
@MainActor
final class BrowserPrompt: Identifiable {
    enum Kind {
        case dialog(BrowserDialogKind, message: String, defaultText: String)
        case credentials(host: String, realm: String, isProxy: Bool)
        case permissions(BrowserPermission, origin: String)
    }

    let id: UUID
    let kind: Kind
    private var reply: ((Answer) -> Void)?

    enum Answer {
        case accept(text: String = "")
        case credentials(user: String, password: String)
        case decline
    }

    init(id: UUID = UUID(), kind: Kind, reply: @escaping (Answer) -> Void) {
        self.id = id
        self.kind = kind
        self.reply = reply
    }

    /// Answers the page. Only the first answer counts.
    func answer(_ answer: Answer) {
        reply?(answer)
        reply = nil
    }
}

/// One browser tab of a pane browser. It holds a page while the browser is
/// running, and only the page's address and title while it is suspended
/// (A7) or before it is first shown after a launch.
@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()
    /// Nil while the tab is suspended, and once the page has closed.
    private(set) var page: BrowserPage?
    private(set) var url: String
    private(set) var title: String
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the page's renderer process ended, while the page shows nothing
    /// for it (A8).
    private(set) var crashReason: String?
    /// The prompts the page is waiting on, oldest first.
    private(set) var prompts: [BrowserPrompt] = []
    /// Whether the page's view exists, and so can be put on screen.
    private(set) var hasView = false
    private(set) var cdpTargetID: String?

    @ObservationIgnored weak var owner: PaneBrowser?

    init(url: String, title: String = "") {
        self.url = url
        self.title = title
    }

    /// A tab for a page that already exists: a popup the page in another tab
    /// opened.
    init(popup: BrowserPage) {
        self.url = popup.url
        self.title = popup.title
        super.init()
        attach(popup)
    }

    /// What the tab is called on screen.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if url.isEmpty || url == "about:blank" {
            // Keyed apart from "New Tab", which the app says of herdr's tabs.
            return String(localized: "BrowserTab.Untitled", defaultValue: "New Tab")
        }
        return url
    }

    /// Opens the tab's page, under `profile`, in `parent` (the holder window;
    /// see `BrowserStore`).
    func start(profile: BrowserProfile, parent: NSView) {
        guard page == nil else { return }
        attach(BrowserPage(url: url.isEmpty ? "about:blank" : url, profile: profile, parentView: parent, delegate: self))
    }

    private func attach(_ page: BrowserPage) {
        self.page = page
        page.delegate = self
        hasView = page.view != nil
        crashReason = nil
    }

    /// Closes the page, keeping the address and title. Unless `force`, the
    /// page may ask whether to leave first.
    func stop(force: Bool) {
        let closing = page
        if force {
            // CEF may call OnBeforeClose synchronously. A forced suspension
            // keeps this tab/URL, so detach its delegate before native close.
            detachPage()
        }
        closing?.closeForcing(force)
    }

    private func detachPage() {
        page?.delegate = nil
        page = nil
        hasView = false
        cdpTargetID = nil
        isLoading = false
        for prompt in prompts {
            prompt.answer(.decline)
        }
        prompts = []
    }

    func load(_ address: String) {
        url = address
        page?.loadURL(address)
    }

    func reload() {
        crashReason = nil
        page?.reload()
    }

    /// Puts a question to the person. `reply` gets their answer once the
    /// prompt is off the list.
    private func ask(_ kind: BrowserPrompt.Kind, reply: @escaping (BrowserPrompt.Answer) -> Void) {
        let id = UUID()
        prompts.append(BrowserPrompt(id: id, kind: kind) { [weak self] answer in
            self?.prompts.removeAll { $0.id == id }
            reply(answer)
        })
    }
}

extension BrowserTab: BrowserPageDelegate {
    func page(_ page: BrowserPage, downloadDidChange metadata: [String: Any]) {
        var info = metadata
        if let id = cdpTargetID { info["frameId"] = id }
        owner?.agentDownloadChanged?(info)
    }

    private func updateTargetID(_ page: BrowserPage) {
        guard page.view != nil else { return }
        page.runDevToolsMethod("Page.getFrameTree", parameters: nil) { [weak self, weak page] result, _ in
            guard let self, let page, self.page === page, let result,
                  let data = result.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tree = json["frameTree"] as? [String: Any], let frame = tree["frame"] as? [String: Any],
                  let id = frame["id"] as? String else { return }
            self.cdpTargetID = id
        }
    }

    func pageDidCreateView(_ page: BrowserPage) {
        hasView = true
        if owner?.agentConnected == true {
            page.agentControlled = true
            if let owner, let store = owner.store { page.agentDownloadFolder = store.downloadFolder(for: owner).path }
        }
        updateTargetID(page)
        owner?.tabDidCreateView(self)
    }

    func pageDidChangeState(_ page: BrowserPage) {
        url = page.url
        title = page.title
        isLoading = page.isLoading
        canGoBack = page.canGoBack
        canGoForward = page.canGoForward
        updateTargetID(page)
        owner?.tabDidChange(self)
    }

    func page(_ page: BrowserPage, didOpenPopup popup: BrowserPage, inBackground: Bool) {
        owner?.adopt(BrowserTab(popup: popup), after: self, select: !inBackground)
    }

    func page(_ page: BrowserPage, requestsNewPageWithURL url: String, inBackground: Bool) {
        owner?.openTab(url: url, after: self, select: !inBackground)
    }

    func page(_ page: BrowserPage, renderProcessDidTerminateWithReason reason: String) {
        crashReason = reason
        isLoading = false
    }

    func page(
        _ page: BrowserPage,
        runDialog kind: BrowserDialogKind,
        message: String,
        defaultText: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        ask(.dialog(kind, message: message, defaultText: defaultText)) { answer in
            switch answer {
            case .accept(let text): completion(true, text)
            case .credentials, .decline: completion(false, "")
            }
        }
    }

    func pageDidDismissDialog(_ page: BrowserPage) {
        // The page stopped waiting: its dialogs mean nothing any more.
        for prompt in prompts {
            if case .dialog = prompt.kind { prompt.answer(.decline) }
        }
    }

    func page(
        _ page: BrowserPage,
        requestCredentialsForHost host: String,
        realm: String,
        isProxy: Bool,
        completion: @escaping (String?, String?) -> Void
    ) {
        ask(.credentials(host: host, realm: realm, isProxy: isProxy)) { answer in
            if case .credentials(let user, let password) = answer {
                completion(user, password)
            } else {
                completion(nil, nil)
            }
        }
    }

    func page(
        _ page: BrowserPage,
        requestPermissions permissions: BrowserPermission,
        forOrigin origin: String,
        completion: @escaping (Bool) -> Void
    ) {
        ask(.permissions(permissions, origin: origin)) { answer in
            if case .accept = answer { completion(true) } else { completion(false) }
        }
    }

    func pageDidDismissPermissionRequest(_ page: BrowserPage) {
        for prompt in prompts {
            if case .permissions = prompt.kind { prompt.answer(.decline) }
        }
    }

    func pageDidClose(_ page: BrowserPage) {
        guard page === self.page else { return }
        detachPage()
        owner?.tabDidClose(self)
    }
}
#endif
