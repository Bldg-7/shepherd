#if os(macOS)
import SwiftUI

/// The browser column beside the terminal: the browser of the pane the
/// window shows — for a tab, the pane last clicked in it (plan item A2) —
/// with its address bar and tabs.
struct BrowserColumn: View {
    /// The pane whose browser to show, or nil while no pane is selected.
    let target: Target?

    struct Target: Equatable {
        let key: BrowserKey
        let terminalID: String
    }

    /// This window's place for a page. Kept for as long as the column is.
    @State private var region = BrowserRegion()
    @State private var isConfirmingProfileSwitch = false

    private var store: BrowserStore { .shared }

    var body: some View {
        let browser = target.flatMap { store.browser(for: $0.key) }
        VStack(spacing: 0) {
            // Not while another window shows the browser: its controls
            // would act on a page this window doesn't show.
            if let browser, store.isShown(browser.key, in: region) {
                if let error = store.engineError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                } else if browser.agentSocketConnected {
                    Label("Agent controlling this browser", systemImage: "cursorarrow.rays")
                        .font(.caption).foregroundStyle(.secondary).padding(6)
                        .accessibilityLabel("Agent connected; user input is also allowed")
                }
                BrowserToolbar(browser: browser, isConfirmingProfileSwitch: $isConfirmingProfileSwitch)
                Divider()
            }
            ZStack {
                BrowserRegionView(region: region, key: target?.key, terminalID: target?.terminalID)
                cover(over: browser)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            "Share a profile with other panes?",
            isPresented: $isConfirmingProfileSwitch,
            titleVisibility: .visible
        ) {
            Button("Use Shared Profile", role: .destructive) {
                browser?.switchProfile(to: .shared)
            }
        } message: {
            Text("This pane's own sign-ins and site data will be deleted.")
        }
    }

    /// What goes over the page: everything the column shows instead of it,
    /// or on top of it.
    @ViewBuilder
    private func cover(over browser: PaneBrowser?) -> some View {
        if !BrowserEngine.isAvailable {
            ContentUnavailableView(
                "No Browser",
                systemImage: "globe",
                description: Text("The browser needs a Mac with Apple silicon.")
            )
            .fillingColumn()
        } else if let target {
            if let browser {
                if !store.isShown(target.key, in: region) {
                    ContentUnavailableView {
                        Label("Shown in Another Window", systemImage: "macwindow.on.rectangle")
                    } description: {
                        Text("This pane's browser is open in another window.")
                    } actions: {
                        Button("Show Here") {
                            store.bringBrowser(to: region)
                        }
                    }
                    .fillingColumn()
                } else if let tab = browser.selectedTab {
                    pageCover(tab, in: browser)
                }
            } else {
                ContentUnavailableView {
                    Label("No Browser", systemImage: "globe")
                } description: {
                    if let error = store.engineError {
                        Text(error)
                    } else {
                        Text("Each pane can have a browser of its own, which stays with the pane.")
                    }
                } actions: {
                    Button("Open Browser") {
                        store.openBrowser(for: target.key, terminalID: target.terminalID)
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .fillingColumn()
            }
        } else {
            ContentUnavailableView(
                "No Pane Selected",
                systemImage: "globe",
                description: Text("Select a pane to see its browser.")
            )
            .fillingColumn()
        }
    }

    @ViewBuilder
    private func pageCover(_ tab: BrowserTab, in browser: PaneBrowser) -> some View {
        if let reason = tab.crashReason {
            ContentUnavailableView {
                Label("This Page Stopped Working", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: reason)
            } actions: {
                Button("Reload") {
                    tab.reload()
                }
            }
            .fillingColumn()
        } else if browser.isSuspended || !tab.hasView {
            if let error = store.engineError {
                ContentUnavailableView("No Browser", systemImage: "globe", description: Text(error))
                    .fillingColumn()
            } else {
                ProgressView()
                    .fillingColumn()
            }
        } else if let prompt = tab.prompts.first {
            ZStack {
                Color.black.opacity(0.15)
                BrowserPromptView(prompt: prompt)
                    .id(prompt.id)
                    .padding(16)
            }
        }
    }
}

private extension View {
    /// Covers the whole column, page and all, rather than only the room the
    /// view itself takes.
    func fillingColumn() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
    }
}

/// Back, forward, reload, the address field, and the browser's menu; below
/// them the tabs, when there is more than one.
private struct BrowserToolbar: View {
    let browser: PaneBrowser
    @Binding var isConfirmingProfileSwitch: Bool

    @State private var address = ""
    @FocusState private var isEditingAddress: Bool

    var body: some View {
        let tab = browser.selectedTab
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    tab?.page?.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .disabled(!(tab?.canGoBack ?? false))
                .help("Back")
                Button {
                    tab?.page?.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.forward")
                }
                .disabled(!(tab?.canGoForward ?? false))
                .help("Forward")
                if tab?.isLoading ?? false {
                    Button {
                        tab?.page?.stopLoading()
                    } label: {
                        Label("Stop", systemImage: "xmark")
                    }
                    .help("Stop")
                } else {
                    Button {
                        tab?.reload()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .help("Reload")
                }
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($isEditingAddress)
                    .onSubmit {
                        guard let tab else { return }
                        tab.load(Self.address(for: address))
                        isEditingAddress = false
                        tab.page?.focus()
                    }
                    .padding(.horizontal, 4)
                Button {
                    browser.openTab(url: "about:blank")
                    isEditingAddress = true
                } label: {
                    // Not "New Tab", which the app says of herdr's tabs.
                    Label("New Browser Tab", systemImage: "plus")
                }
                .help("New Browser Tab")
                menu
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            if browser.tabs.count > 1 {
                BrowserTabStrip(browser: browser)
            }
        }
        .onAppear { address = Self.shownAddress(tab?.url) }
        .onChange(of: tab?.url) { _, url in
            if !isEditingAddress {
                address = Self.shownAddress(url)
            }
        }
        .onChange(of: tab?.id) {
            address = Self.shownAddress(tab?.url)
            if tab?.url == "about:blank" {
                isEditingAddress = true
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Profile", selection: Binding(
                get: { browser.profile.isShared },
                set: { shared in
                    if shared {
                        isConfirmingProfileSwitch = true
                    } else {
                        browser.switchProfile(to: .newIsolated())
                    }
                }
            )) {
                Text("This Pane Only").tag(false)
                Text("Shared with Other Panes").tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Button("Close Browser") {
                BrowserStore.shared.closeBrowser(for: browser.key)
            }
        } label: {
            Label("Browser", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Browser")
    }

    /// What the address field shows for a page's address: nothing for a
    /// blank page, so that typing starts in an empty field.
    private static func shownAddress(_ url: String?) -> String {
        guard let url, url != "about:blank" else { return "" }
        return url
    }

    /// What typing `input` into the address field opens: the address, made
    /// complete, or a web search for it.
    static func address(for input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "about:blank" }
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("about:") || lowered.hasPrefix("data:") {
            return text
        }
        if !text.contains(" ") {
            let host = lowered.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lowered
            let hostName = host.split(separator: ":").first.map(String.init) ?? host
            let labels = hostName.split(separator: ".")
            let isIPv4 = labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
            if hostName == "localhost" || hostName.hasSuffix(".localhost") || isIPv4 {
                return "http://" + text
            }
            if hostName.contains(".") {
                return "https://" + text
            }
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url?.absoluteString ?? "about:blank"
    }
}

/// A pane browser's tabs, one chip each.
private struct BrowserTabStrip: View {
    let browser: PaneBrowser

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(browser.tabs) { tab in
                    chip(for: tab)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private func chip(for tab: BrowserTab) -> some View {
        let isSelected = tab.id == browser.selectedTab?.id
        return HStack(spacing: 4) {
            if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
            } else if !tab.prompts.isEmpty {
                // The page is waiting on the person.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }
            Text(verbatim: tab.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
            Button {
                browser.close(tab)
            } label: {
                Label("Close Browser Tab", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Close Browser Tab")
        }
        .font(.callout)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            browser.select(tab)
        }
    }
}
#endif
