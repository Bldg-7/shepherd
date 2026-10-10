#if os(macOS)
import AppKit
import Observation
import CryptoKit

/// The browser of one pane: its tabs and the profile they all use.
///
/// It outlives every view of it — `BrowserStore` owns it — so switching to
/// another pane and back leaves its pages as they were (plan item A1). Its
/// pages can be closed to save memory while its tabs stay, as addresses and
/// titles: then it is suspended (A7), and opens them again when it is next
/// shown. A pane browser restored at launch starts out suspended too.
@MainActor
@Observable
final class PaneBrowser {
    private(set) var key: BrowserKey
    /// The terminal in the pane, which tells this pane from a later one that
    /// got the same pane ID (B3).
    let terminalID: String
    private(set) var profile: ProfileChoice
    private(set) var tabs: [BrowserTab] = []
    private(set) var selectedTabID: UUID?
    /// Whether no tab has a page open — then `suspend` has nothing to close.
    private(set) var isSuspended = true
    /// Native lease/cleanup guard; quarantine keeps this true.
    var agentConnected = false
    /// A live authenticated socket, independently of native cleanup holds.
    var agentSocketConnected = false
    @ObservationIgnored var agentDownloadChanged: (([String: Any]) -> Void)?
    var downloadID: String {
        let identity = "\(key.machineID)/\(key.herdrMachineID ?? "")/\(key.session)/\(terminalID)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func remap(to key: BrowserKey) { self.key = key }

    /// When it was last on screen, for choosing which browser to suspend.
    @ObservationIgnored var lastShown = Date.distantPast
    @ObservationIgnored weak var store: BrowserStore?

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    init(key: BrowserKey, terminalID: String, profile: ProfileChoice, tabURLs: [String] = [], selectedTab: Int = 0, store: BrowserStore) {
        self.key = key
        self.terminalID = terminalID
        self.profile = profile
        self.store = store
        self.tabs = tabURLs.map { BrowserTab(url: $0) }
        for tab in tabs {
            tab.owner = self
        }
        selectedTabID = tabs.indices.contains(selectedTab) ? tabs[selectedTab].id : tabs.first?.id
    }

    /// The tab addresses and which one is selected, as `browsers.json`
    /// keeps them.
    var record: BrowserRecord {
        BrowserRecord(
            key: key,
            terminalID: terminalID,
            profile: profile,
            tabURLs: tabs.map(\.url),
            selectedTab: tabs.firstIndex { $0.id == selectedTab?.id } ?? 0
        )
    }

    // MARK: Running and suspending

    /// Opens the pages of every tab. False if the browser engine couldn't be
    /// started (`BrowserStore.engineError` says why).
    @discardableResult
    func resume() -> Bool {
        guard ShepherdBrowserFeature.shared.isEnabled else { return false }
        guard isSuspended else { return true }
        guard startPages(of: tabs) else { return false }
        isSuspended = false
        return true
    }

    /// Closes every page, keeping the tabs.
    func suspend() {
        guard !isSuspended else { return }
        for tab in tabs {
            tab.stop(force: true)
        }
        isSuspended = true
    }

    /// Closes every page and forgets the tabs. The profile stays.
    func closeAllTabs() {
        suspend()
        tabs = []
        selectedTabID = nil
        store?.browserDidChange(self)
    }

    /// Opens the pages of `tabs`, under the browser's profile. False if the
    /// browser engine couldn't be started.
    @discardableResult
    private func startPages(of tabs: [BrowserTab]) -> Bool {
        guard let store, let profile = store.profile(for: profile) else { return false }
        for tab in tabs {
            tab.start(profile: profile, parent: store.holderView)
        }
        return true
    }

    // MARK: Tabs

    func select(_ tab: BrowserTab) {
        guard selectedTabID != tab.id else { return }
        selectedTabID = tab.id
        store?.browserDidChange(self)
    }

    /// Opens a new tab — after `neighbour`, or last — and selects it unless
    /// it is to open in the background.
    @discardableResult
    func openTab(url: String, after neighbour: BrowserTab? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url)
        insert(tab, after: neighbour, select: select)
        if !isSuspended {
            startPages(of: [tab])
        }
        store?.browserDidChange(self)
        return tab
    }

    /// Takes in a tab whose page another tab's page opened (a popup).
    func adopt(_ tab: BrowserTab, after neighbour: BrowserTab, select: Bool) {
        insert(tab, after: neighbour, select: select)
        store?.browserDidChange(self)
    }

    private func insert(_ tab: BrowserTab, after neighbour: BrowserTab?, select: Bool) {
        tab.owner = self
        if let neighbour, let index = tabs.firstIndex(where: { $0 === neighbour }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select || selectedTabID == nil {
            selectedTabID = tab.id
        }
    }

    /// Closes a tab. Its page may first ask whether to leave; the tab goes
    /// once the page has closed (`tabDidClose`). A tab without a page goes
    /// at once.
    func close(_ tab: BrowserTab) {
        if tab.page == nil {
            remove(tab)
        } else {
            tab.stop(force: false)
        }
    }

    func tabDidClose(_ tab: BrowserTab) {
        remove(tab)
    }

    private func remove(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            // The tab that took its place, else the one before it.
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        if tabs.isEmpty {
            isSuspended = true
        }
        store?.browserDidChange(self)
    }

    func tabDidCreateView(_ tab: BrowserTab) {
        store?.layout()
    }

    func tabDidChange(_ tab: BrowserTab) {
        store?.browserDidChange(self, layout: false)
    }

    // MARK: Profile

    /// Moves the browser to another profile (A14). A profile is fixed when a
    /// page is created, so every page is closed and opened again, at the
    /// address it was at, under the new one. The isolated profile it leaves
    /// is deleted, logins and all.
    func switchProfile(to newProfile: ProfileChoice) {
        guard ShepherdBrowserFeature.shared.isEnabled else { return }
        guard newProfile != profile, let store else { return }
        CDPProxy.shared.invalidate(self)
        let wasRunning = !isSuspended
        suspend()
        let oldFolder = profile.isolatedFolder
        profile = newProfile
        if let oldFolder {
            store.discardProfileFolder(oldFolder)
        }
        if wasRunning {
            resume()
        }
        store.browserDidChange(self)
    }
}
#endif
