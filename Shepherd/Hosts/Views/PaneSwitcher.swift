import SwiftUI

/// Uses the board's existing snapshots: no additional connection or agent launch.
struct PaneDestination: Identifiable, Equatable {
    let pane: AgentSummary
    let item: BoardItem
    let location: String
    let isAvailable: Bool
    var id: String { pane.id }
    static func resolve(_ requested: Self, in destinations: [Self], contextMatches: Bool) -> Self? {
        guard contextMatches else { return nil }
        return destinations.first { $0.id == requested.id && $0.pane.terminalID == requested.pane.terminalID && $0.isAvailable }
    }
    func matches(_ query: String) -> Bool {
        let texts = [pane.title, pane.id, pane.agentName ?? "", pane.workingDirectory ?? "", location]
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            texts.contains { $0.localizedStandardContains(String(term)) }
        }
    }
}

nonisolated struct TerminalPaneFocus: Equatable, Sendable {
    let paneID: String // qualified by herdr machine, not raw w1:p1
    let token = UUID()
}
extension EnvironmentValues {
    @Entry var terminalPaneFocus: TerminalPaneFocus?
}

struct PaneSwitcher: View {
    let destinations: [PaneDestination]
    let onSelect: (PaneDestination) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var fieldFocused: Bool
    private var results: [PaneDestination] { destinations.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to Agent or Pane…", text: $query)
                    .textFieldStyle(.plain).focused($fieldFocused)
                    .onSubmit { chooseHighlighted() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel")
            }.padding(16)
            Divider()
            if results.isEmpty {
                ContentUnavailableView.search(text: query).frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(results) { destination in
                                Button { if destination.isAvailable { onSelect(destination) } } label: {
                                    HStack {
                                        Image(systemName: destination.pane.hasAgent ? "person.crop.rectangle" : "terminal")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(verbatim: destination.pane.title).lineLimit(1)
                                            Text(verbatim: destination.location + " · " + destination.pane.id)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if !destination.isAvailable { Image(systemName: "wifi.slash").foregroundStyle(.secondary) }
                                        else if destination.id == highlightedID { Image(systemName: "return").foregroundStyle(.secondary) }
                                    }
                                    .padding(10).contentShape(Rectangle())
                                    .background(destination.id == highlightedID ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain).disabled(!destination.isAvailable)
                                .id(destination.id)
                            }
                        }.padding(8)
                    }
                    .frame(height: 320)
                    .onChange(of: highlightedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 540, maxWidth: 600)
        .onAppear { fieldFocused = true; reconcileHighlight() }
        .onChange(of: query) { reconcileHighlight() }
        .onChange(of: destinations) { reconcileHighlight() }
        #if os(macOS)
        .onExitCommand(perform: onClose)
        #endif
    }
    private func reconcileHighlight() {
        if !results.contains(where: { $0.id == highlightedID && $0.isAvailable }) {
            highlightedID = results.first(where: \.isAvailable)?.id
        }
    }
    private func move(_ delta: Int) {
        let choices = results.filter(\.isAvailable)
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex { $0.id == highlightedID } ?? 0
        highlightedID = choices[min(choices.count - 1, max(0, index + delta))].id
    }
    private func chooseHighlighted() {
        if let destination = results.first(where: { $0.id == highlightedID && $0.isAvailable }) { onSelect(destination) }
    }
}
