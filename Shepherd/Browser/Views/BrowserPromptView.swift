#if os(macOS)
import SwiftUI

/// A page's question to the person, over the page: a JavaScript dialog, a
/// server's sign-in, or a site asking for permissions (plan items A9, A10).
struct BrowserPromptView: View {
    let prompt: BrowserPrompt

    @State private var text = ""
    @State private var user = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch prompt.kind {
            case .dialog(let kind, let message, let defaultText):
                dialog(kind, message: message)
                    .onAppear { text = defaultText }
            case .credentials(let host, let realm, let isProxy):
                credentials(host: host, realm: realm, isProxy: isProxy)
            case .permissions(let permissions, let origin):
                permissionRequest(permissions, origin: origin)
            }
        }
        .padding(18)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
    }

    @ViewBuilder
    private func dialog(_ kind: BrowserDialogKind, message: String) -> some View {
        if kind == .beforeUnload {
            Text("Leave this page?")
                .font(.headline)
            Text("Changes you made may not be saved.")
        } else {
            Text("The page says:")
                .font(.headline)
            ScrollView {
                Text(verbatim: message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
            if kind == .prompt {
                TextField(text: $text) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { prompt.answer(.accept(text: text)) }
            }
        }
        HStack {
            Spacer()
            if kind != .alert {
                Button(kind == .beforeUnload ? "Stay" : "Cancel", role: .cancel) {
                    prompt.answer(.decline)
                }
                .keyboardShortcut(.cancelAction)
            }
            Button(kind == .beforeUnload ? "Leave" : "OK") {
                prompt.answer(.accept(text: text))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func credentials(host: String, realm: String, isProxy: Bool) -> some View {
        Group {
            if isProxy {
                Text("Sign in to the proxy server \(host)")
            } else {
                Text("Sign in to \(host)")
            }
        }
        .font(.headline)
        if !realm.isEmpty {
            Text(verbatim: realm)
                .foregroundStyle(.secondary)
        }
        TextField("User Name", text: $user)
            .textFieldStyle(.roundedBorder)
        SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
            .onSubmit { prompt.answer(.credentials(user: user, password: password)) }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                prompt.answer(.decline)
            }
            .keyboardShortcut(.cancelAction)
            Button("Sign In") {
                prompt.answer(.credentials(user: user, password: password))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func permissionRequest(_ permissions: BrowserPermission, origin: String) -> some View {
        Text("\(origin) wants to:")
            .font(.headline)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.names(of: permissions), id: \.self) { name in
                Label(name, systemImage: "checkmark.shield")
            }
        }
        HStack {
            Spacer()
            Button("Don't Allow", role: .cancel) {
                prompt.answer(.decline)
            }
            .keyboardShortcut(.cancelAction)
            Button("Allow") {
                prompt.answer(.accept())
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// What a site asking for `permissions` wants to do, in words.
    private static func names(of permissions: BrowserPermission) -> [String] {
        let descriptions: [(BrowserPermission, String)] = [
            (.geolocation, String(localized: "Know your location")),
            (.notifications, String(localized: "Show notifications")),
            (.clipboard, String(localized: "See what you copy to the clipboard")),
            (.camera, String(localized: "Use your camera")),
            (.microphone, String(localized: "Use your microphone")),
            (.midiSysex, String(localized: "Use your MIDI devices")),
            ([.storageAccess, .topLevelStorageAccess], String(localized: "Use its cookies and site data on this site")),
            (.windowManagement, String(localized: "Manage windows on all your displays")),
            (.fileSystemAccess, String(localized: "Edit files on this Mac")),
            (.localFonts, String(localized: "Use the fonts on this Mac")),
            (.idleDetection, String(localized: "Know when you're using this Mac")),
            (.multipleDownloads, String(localized: "Download multiple files")),
        ]
        let names = descriptions.filter { !permissions.intersection($0.0).isEmpty }.map(\.1)
        return names.isEmpty ? [String(localized: "Use other features")] : names
    }
}
#endif
