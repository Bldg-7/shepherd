import SwiftUI

/// The licenses of the open-source code the app is built with, as
/// ThirdPartyNotices.txt (next to this file, in the app's bundle) has them:
/// each one under the path its text came from.
struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: Self.notices.introduction)
                        .font(.footnote)
                    ForEach(Self.notices.sections.indices, id: \.self) { index in
                        let section = Self.notices.sections[index]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: section.title)
                                .font(.footnote.weight(.semibold))
                            Text(verbatim: section.text)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 12)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Open Source Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private struct Notices {
        var introduction = ""
        var sections: [(title: String, text: String)] = []
    }

    /// The file is a line of introduction, then sections, each a title
    /// between two rules of `=` and the text up to the next rule.
    private static let notices: Notices = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Notices() }
        let parts = text.components(separatedBy: "\n" + String(repeating: "=", count: 72) + "\n")
        var notices = Notices(introduction: parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
        for index in stride(from: 1, to: parts.count - 1, by: 2) {
            let title = parts[index]
                .replacingOccurrences(of: "build/SourcePackages/checkouts/", with: "")
                .replacingOccurrences(of: "Vendor/", with: "")
            notices.sections.append((title, parts[index + 1].trimmingCharacters(in: .newlines)))
        }
        return notices
    }()
}
