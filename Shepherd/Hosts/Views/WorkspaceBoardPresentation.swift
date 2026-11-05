import SwiftUI

/// Existing board presentation, shared by the old data source and hc. These
/// views have no transport, process/session identity or mutation authority.
struct WorkspaceBoardStatusIndicator: View {
    let state: AgentState?
    var body: some View {
        Group {
            if let state { Circle().fill(color(state)).frame(width: 10, height: 10) }
            else { Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary) }
        }.frame(width: 10)
    }
    private func color(_ state: AgentState) -> Color {
        switch state {
        case .idle: .gray
        case .working: .blue
        case .blocked: .orange
        case .done: .green
        case .unknown: .secondary
        }
    }
}
struct WorkspaceBoardRow<Accessory: View, Caption: View>: View {
    let title: String
    let state: AgentState?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var caption: () -> Caption
    var body: some View {
        HStack {
            WorkspaceBoardStatusIndicator(state: state)
            VStack(alignment: .leading) {
                HStack(spacing: 6) { Text(title).font(.body); accessory() }
                caption()
            }
            Spacer()
            if let state { Text(state.title).font(.caption).foregroundStyle(.secondary) }
        }
        #if os(macOS)
        .padding(.trailing, 6)
        #endif
    }
}
struct WorkspaceBoardSearchBar<Filter: View>: View {
    @Binding var text: String
    @ViewBuilder var filter: () -> Filter
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter", text: $text).textFieldStyle(.plain).accessibilityIdentifier("workspace.board.filter")
                #if os(macOS)
                .onExitCommand { text = "" }
                #endif
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(Text("Clear"))
            }
            filter()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
struct WorkspaceBoardTabModeBar: View {
    @Binding var showsTabs: Bool
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Group by Tab")
                Spacer()
                Toggle("Group by Tab", isOn: $showsTabs).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityIdentifier("workspace.board.group-by-tab")
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.bar, ignoresSafeAreaEdges: [.horizontal, .bottom])
        .help("Show each tab as one row, and all of its panes at once when it is selected.")
    }
}
struct WorkspaceBoardSectionLabel: View {
    let title: String
    var body: some View {
        Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .lineLimit(1).padding(.top, 4).selectionDisabled().accessibilityAddTraits(.isHeader)
    }
}
