import SwiftUI

#if os(macOS)
/// The ⓘ beside a setting's label. Hovering shows the explanation as a
/// tooltip; clicking opens it in a popover, which closes again on a click
/// outside it, the ⓘ included, or on Escape.
struct InfoButton: View {
    let accessibilityLabel: LocalizedStringKey
    let explanation: LocalizedStringKey
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityLabel)
        .help(explanation)
        .popover(isPresented: $isPresented) {
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding()
        }
    }
}
#endif
