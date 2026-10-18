import SwiftUI
import ShepherdKit

/// What a pane's terminal last printed: the recent rows of its scrollback,
/// read once when the view appears and again, with more rows, when pulled
/// down. Read only — nothing is typed into the pane, and nothing is taken
/// from whoever is attached to it (docs/mobile-design.md, section 3).
struct PaneOutputView: View {
    let destination: PaneDestination
    let machineStore: MachineStore
    @State private var text: String?
    @State private var truncated = false
    @State private var failure: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if truncated {
                    Text("Older output can't be read from this device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if let text {
                    Text(verbatim: text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isLoading {
                    ProgressView()
                }
            }
            .padding()
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(lines: 1000) }
        .task { await load(lines: nil) }
    }

    /// Reads the pane over a connection of its own, opened for the read and
    /// closed after it.
    private func load(lines: Int?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = HerdrClient(transport: try machineStore.makeHerdrTransport(for: destination.machine))
            try await client.connect()
            let read: PaneRead
            do {
                read = try await client.readPane(destination.paneID, source: .recentUnwrapped, lines: lines, on: destination.herdrMachine)
            } catch {
                await client.disconnect()
                throw error
            }
            await client.disconnect()
            text = Self.trimmed(read.text)
            truncated = read.truncated
            failure = nil
        } catch {
            failure = connectionFailureDescription(error)
        }
    }

    /// Without the blank rows a terminal keeps below its last line.
    private static func trimmed(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
