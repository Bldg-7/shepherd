import SwiftUI
import UIKit
import ShepherdKit

/// Registers a machine. A fresh Ed25519 key is made for it on this device
/// (`DeviceKey`), and only its public line is shown, for the person to add
/// to the machine's `~/.ssh/authorized_keys`; the private key goes into
/// this device's Keychain with the machine.
struct AddMachineView: View {
    let machineStore: MachineStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var session = ""
    @State private var key = DeviceKey()
    @State private var failure: String?

    /// How the key reads in `authorized_keys`, so that it can be told from
    /// other keys and removed there.
    private var comment: String { "shepherd-mobile \(UIDevice.current.name)" }

    private var authorizedKeysLine: String { key.authorizedKeysLine(comment: comment) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Machine") {
                    TextField("Name", text: $name)
                    TextField("Hostname", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("herdr session (optional)", text: $session)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text(verbatim: authorizedKeysLine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button("Copy Key") {
                        UIPasteboard.general.string = authorizedKeysLine
                    }
                } header: {
                    Text("This Device's Key")
                } footer: {
                    Text("Add this line to ~/.ssh/authorized_keys on the machine. The private key never leaves this device.")
                }
                if let failure {
                    Section {
                        Text(verbatim: failure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !trimmed(name).isEmpty && !trimmed(hostname).isEmpty && Int(port).map { (1...65535).contains($0) } == true
            && !trimmed(username).isEmpty && Machine.normalizedSessionName(session) != nil
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard let port = Int(port), let session = Machine.normalizedSessionName(session) else { return }
        let machine = Machine(displayName: trimmed(name), hostname: trimmed(hostname), port: port,
                              username: trimmed(username), authMethod: .key, sessionName: session)
        do {
            try machineStore.addMachine(machine, privateKey: key.privateKeyPEM(comment: comment))
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
