import SwiftUI

/// Backend-independent data for the existing switcher presentation.
struct WorkspaceSwitcherItem<ID: Hashable>: Identifiable, Equatable {
    let id: ID
    let title: String
    let location: String
    let searchTerms: [String]
    let hasAgent: Bool
    let isAvailable: Bool
    var accessibilityID: String? = nil
    static func submitted(in results: [Self], highlightedID: ID?) -> Self? {
        // onChange reconciliation may follow the submit event. Never look up
        // an old destination outside the CURRENT filtered snapshot.
        results.first { $0.id == highlightedID && $0.isAvailable } ?? results.first(where: \.isAvailable)
    }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            ([title,location] + searchTerms).contains { $0.localizedStandardContains(String(term)) }
        }
    }
}
struct WorkspacePaneSwitcher<ID: Hashable>: View {
    let destinations: [WorkspaceSwitcherItem<ID>]
    let onSelect: (WorkspaceSwitcherItem<ID>) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @State private var highlightedID: ID?
    @FocusState private var fieldFocused: Bool
    private var results: [WorkspaceSwitcherItem<ID>] { destinations.filter { $0.matches(query) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to Agent or Pane…", text: $query)
                    .textFieldStyle(.plain).focused($fieldFocused).accessibilityIdentifier("workspace.switcher.search")
                    .onSubmit { chooseHighlighted() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Cancel").accessibilityIdentifier("workspace.switcher.cancel")
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
                                        Image(systemName: destination.hasAgent ? "person.crop.rectangle" : "terminal")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(verbatim: destination.title).lineLimit(1)
                                            Text(verbatim: destination.location)
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
                                .accessibilityIdentifier(destination.accessibilityID ?? String(describing:destination.id))
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
        if let destination = WorkspaceSwitcherItem.submitted(in:results,highlightedID:highlightedID) { onSelect(destination) }
    }
}
