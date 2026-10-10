import SwiftUI
#if canImport(Citadel)
import AppKit
#endif

struct AddMachineView: View {
    let machineStore: MachineStore
    /// How to leave this view, for a presenter that isn't a sheet of its
    /// own. On macOS it is a page of the Machines sheet, and the
    /// environment's `dismiss` would close that whole sheet instead of
    /// going back to the list.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var sessionName = ""
    @State private var authMethod: Machine.AuthMethod = .key
    @State private var privateKeyText = ""
    @State private var password = ""
    @State private var errorMessage: String?

    #if canImport(Citadel)
    private enum KeySource: CaseIterable, Identifiable {
        case generate
        case paste
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .generate: "Generate New Key"
            case .paste: "Paste Existing Key"
            }
        }
    }
    @State private var keySource: KeySource = .generate
    @State private var generatedKey = DeviceKey()
    @State private var copiedCommand = false
    #endif

    var body: some View {
        container
            // An alert rather than a line in the form: Save is tapped with
            // the keyboard up and the form scrolled wherever the last field
            // was, so a message added to the form can land out of sight and
            // leave Save looking like it did nothing.
            .alert("Couldn't Save Machine", isPresented: isShowingSaveError, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var container: some View {
        // A page of the Machines sheet (see `MachinesSettingsView`), which
        // has no navigation bar for a back button, a title or toolbar
        // buttons to show up in, so all of them are laid out here: the way
        // back and the title along the top, Cancel and Add along the bottom
        // edge as on any Mac form. Its size is the sheet's.
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    close()
                } label: {
                    Label("Machines", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to Machines")
                Divider()
                    .frame(height: 14)
                Text("Add Machine")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            form
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Machine") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var form: some View {
        Form {
            Section("Machine") {
                TextField("Name", text: $displayName, prompt: requiredPrompt)
                TextField("Hostname", text: $hostname, prompt: requiredPrompt)
                    .autocorrectionDisabled()
                TextField("Port", text: $port, prompt: requiredPrompt)
                TextField("Username", text: $username, prompt: requiredPrompt)
                    .autocorrectionDisabled()
            }
            Section {
                // Above the field, not below it: on iPhone the keyboard
                // covers whatever follows the field being edited, and
                // this is the one line that says why Save is disabled.
                if normalizedSessionName == nil {
                    Text("A session name starts with a letter or digit and uses only letters, digits, \".\", \"_\" and \"-\", up to 64 characters.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Verbatim: "default" is the name of herdr's default session,
                // not a word to translate.
                TextField("Session", text: $sessionName, prompt: Text(verbatim: "default"))
                    .autocorrectionDisabled()
            } header: {
                // On macOS the field's own name already says it; on iOS the
                // field shows only "default", so the header names it.
            } footer: {
                Text("Which of that machine's named herdr sessions to use. Leave blank for \"default\".")
            }
            Section {
                Picker("Method", selection: $authMethod) {
                    Text("Key").tag(Machine.AuthMethod.key)
                    Text("Password").tag(Machine.AuthMethod.password)
                }
                .pickerStyle(.segmented)

                switch authMethod {
                case .key:
                    keyAuthSection
                case .password:
                    SecureField("Password", text: $password, prompt: requiredPrompt)
                }
            } header: {
                Text("Authentication")
            } footer: {
                if let authenticationFooter {
                    Text(authenticationFooter)
                }
            }
        }
    }

    /// What an empty field shows. On macOS the field's name is printed beside
    /// it, and an empty field with no prompt draws nothing at all — not even
    /// an outline — so it says "Required", as System Settings' own forms do.
    /// On iOS the name is all a field shows, so there it stays the name.
    private var requiredPrompt: Text? {
        Text("Required")
    }

    private var authenticationFooter: LocalizedStringKey? {
        switch authMethod {
        case .password:
            return "Stored in the Keychain, never in plain app storage. Many hardened servers disable password login entirely — prefer Key when that's an option."
        case .key:
            #if canImport(Citadel)
            if keySource == .generate { return nil }
            #endif
            return "Paste an OpenSSH private key (PEM). It's stored in the Keychain, never in plain app storage."
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var isShowingSaveError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isShowing in
                if !isShowing { errorMessage = nil }
            }
        )
    }

    @ViewBuilder
    private var keyAuthSection: some View {
        #if canImport(Citadel)
        Picker("Key Source", selection: $keySource) {
            ForEach(KeySource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)

        switch keySource {
        case .generate:
            generatedKeySection
        case .paste:
            pasteKeySection
        }
        #else
        pasteKeySection
        #endif
    }

    #if canImport(Citadel)
    private var generatedKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if hostname.isEmpty {
                    Text("Shepherd generated a key on this device. Run this on the machine to authorize it:")
                } else {
                    Text("Shepherd generated a key on this device. Run this on \(hostname) to authorize it:")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(authorizeCommand)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button {
                copyToClipboard(authorizeCommand)
                copiedCommand = true
            } label: {
                if copiedCommand {
                    Text("Copied")
                } else {
                    Text("Copy Command")
                }
            }
        }
    }

    private var authorizeCommand: String {
        "echo \"\(generatedKey.authorizedKeysLine(comment: deviceKeyComment))\" >> ~/.ssh/authorized_keys"
    }

    /// `displayName`, slugified; falls back to the hardware model identifier
    /// when there's no name yet (e.g. while still filling in the form).
    ///
    /// Slugifying matters beyond cosmetics: this text lands inside
    /// `authorizeCommand`'s double-quoted `echo "..."` string, which a
    /// person is told to paste straight into their shell. An unsanitized
    /// name containing `"`, `` ` ``, or `$` would not just look wrong — it
    /// would inject into that command. Restricting to `[a-z0-9-]` rules
    /// that out entirely, independent of the Name field's own validation.
    private var deviceKeyComment: String {
        let nameSlug = slugify(displayName)
        if !nameSlug.isEmpty {
            return "shepherd-\(nameSlug)"
        }
        let modelSlug = slugify(deviceModelIdentifier)
        return "shepherd-\(modelSlug.isEmpty ? "device" : modelSlug)"
    }

    /// The raw hardware model identifier (e.g. `MacBookPro18,3`, `iPhone16,2`)
    /// — not a marketing name (no public API maps one to the other without a
    /// hand-maintained table), but stable and never empty in practice.
    private var deviceModelIdentifier: String {
        sysctlString("hw.model") ?? ""
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Lowercases and keeps only `[a-z0-9-]`, collapsing any run of other
    /// characters (spaces, Unicode, shell metacharacters) into a single `-`.
    /// See `deviceKeyComment` for why this needs to be airtight, not just tidy.
    private func slugify(_ raw: String) -> String {
        var result = ""
        var lastWasDash = true
        for scalar in raw.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        if result.hasSuffix("-") {
            result.removeLast()
        }
        if result.count > 32 {
            result = String(result.prefix(32))
            while result.hasSuffix("-") {
                result.removeLast()
            }
        }
        return result
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    #endif

    private var pasteKeySection: some View {
        TextEditor(text: $privateKeyText)
            .font(.system(.body, design: .monospaced))
            // A grouped form row draws no field around a text view, which
            // would leave the editor as an unmarked blank stretch of row.
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .frame(height: 120)
    }

    /// What would be stored for the Session field as typed, or nil while it
    /// isn't a usable session name. The name ends up in a socket path and
    /// in a command line run on the machine, so one that doesn't pass
    /// `Machine.normalizedSessionName` blocks Save rather than being saved
    /// and failing (or misbehaving) at connect time.
    private var normalizedSessionName: String? {
        Machine.normalizedSessionName(sessionName)
    }

    /// The text fields as they will be stored. Pasting a hostname or a user
    /// name easily brings a stray space or newline along, which would only
    /// surface later as a lookup or login failure that looks like anything
    /// but a typo.
    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The port as a number SSH can actually use, or nil.
    private var portNumber: Int? {
        guard let number = Int(trimmed(port)), (1...65535).contains(number) else { return nil }
        return number
    }

    private var canSave: Bool {
        guard !trimmed(displayName).isEmpty, !trimmed(hostname).isEmpty, !trimmed(username).isEmpty, portNumber != nil else { return false }
        guard normalizedSessionName != nil else { return false }
        switch authMethod {
        case .password:
            return !password.isEmpty
        case .key:
            #if canImport(Citadel)
            if keySource == .generate { return true }
            #endif
            return !privateKeyText.isEmpty
        }
    }

    private func save() {
        guard let portNumber, let normalizedSessionName else { return }
        let machine = Machine(
            displayName: trimmed(displayName),
            hostname: trimmed(hostname),
            port: portNumber,
            username: trimmed(username),
            authMethod: authMethod,
            sessionName: normalizedSessionName
        )

        do {
            switch authMethod {
            case .password:
                try machineStore.addMachine(machine, password: password)
            case .key:
                let keyData: Data
                #if canImport(Citadel)
                switch keySource {
                case .generate:
                    keyData = generatedKey.privateKeyPEM(comment: deviceKeyComment)
                case .paste:
                    guard let pasted = privateKeyText.data(using: .utf8) else { return }
                    keyData = pasted
                }
                #else
                guard let pasted = privateKeyText.data(using: .utf8) else { return }
                keyData = pasted
                #endif
                try machineStore.addMachine(machine, privateKey: keyData)
            }
            close()
        } catch {
            errorMessage = String(localized: "The machine wasn't added because its credential couldn't be stored. \(error.localizedDescription)")
        }
    }
}
