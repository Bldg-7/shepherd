import SwiftUI
import UIKit

/// Scan Mac's QR Code (SHPHRD-77, "화면 흐름"): the camera, what the code
/// says, the confirmation code while the Mac's owner decides, the first
/// connection, and then the Mac's board. `PairingFlow` decides what is shown;
/// this draws it.
struct PairingSheet: View {
    /// Shows a Mac's board once the sheet has gone.
    let onOpen: (Machine) -> Void
    @State private var flow: PairingFlow
    @Environment(\.dismiss) private var dismiss

    init(machineStore: MachineStore, onOpen: @escaping (Machine) -> Void) {
        self.onOpen = onOpen
        _flow = State(initialValue: PairingFlow(environment: .live(store: machineStore), deviceName: PairingDefaults.deviceName))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isFinishing {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { close() }
                        }
                    }
                }
        }
        .interactiveDismissDisabled(isFinishing)
        .onChange(of: flow.step) { _, step in
            switch step {
            case .paired(let machine, let check) where check.succeeded: open(machine)
            case .moved(let machine): open(machine)
            default: break
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                flow.tick()
            }
        }
        .onDisappear { flow.cancel() }
    }

    private var title: LocalizedStringKey {
        flow.step == .scanning ? "Scan Mac's QR Code" : "Add Mac"
    }

    /// Approved and saved, the first connection under way: the sheet waits
    /// for it.
    private var isFinishing: Bool {
        if case .checking = flow.step { return true }
        return false
    }

    private func close() {
        flow.cancel()
        dismiss()
    }

    private func open(_ machine: Machine) {
        flow.cancel()
        onOpen(machine)
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .scanning:
            PairingScannerView(notice: flow.scanNotice) { flow.scanned($0) }
        case .preview(let payload):
            PairingPreview(flow: flow, payload: payload)
        case .alreadyAdded(let machine):
            outcome(systemImage: "checkmark.circle", tint: .green,
                    message: Text("\(machine.displayName) is already in Machines with this address.")) {
                Button("Open \(machine.displayName)") { open(machine) }
                    .buttonStyle(.borderedProminent)
            }
        case .differentHostKey(let machine):
            outcome(systemImage: "exclamationmark.shield", tint: .orange,
                    message: Text("This QR code is from \(machine.displayName), which is already in Machines, but the Mac's SSH host key isn't the one saved for it, so nothing was changed. If you reinstalled the Mac, remove \(machine.displayName) from Machines first, then scan again.")) {
                Button("Done") { close() }
                    .buttonStyle(.borderedProminent)
            }
        case .newAddress(let machine, let payload):
            NewAddressPreview(flow: flow, machine: machine, payload: payload)
        case .expired:
            outcome(systemImage: "clock", tint: .secondary,
                    message: Text("This QR code has expired. The Mac shows a new one every two minutes.")) {
                scanAgainButton
            }
        case .connecting(let payload):
            progress(Text("Connecting to \(payload.macName)…"))
        case .waitingForApproval(let payload, let code):
            WaitingForApproval(macName: payload.macName, code: code)
        case .checking(let machine):
            progress(Text("Approved. Connecting to \(machine.displayName)…"))
        case .paired(let machine, let check):
            if let summary = PairingFlow.summary(of: check, macName: machine.displayName) {
                outcome(systemImage: "exclamationmark.triangle", tint: .orange, message: Text(verbatim: summary)) {
                    Button("Open \(machine.displayName)") { open(machine) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                progress(Text("Opening \(machine.displayName)…"))
            }
        case .movingAddress(let machine, _):
            progress(Text("Connecting to \(machine.displayName) at its new address…"))
        case .moved(let machine):
            progress(Text("Opening \(machine.displayName)…"))
        case .failed(let message):
            outcome(systemImage: "xmark.octagon", tint: .red, message: Text(verbatim: message)) {
                scanAgainButton
            }
        }
    }

    private var scanAgainButton: some View {
        Button("Scan Again") { flow.scanAgain() }
            .buttonStyle(.borderedProminent)
    }

    private func progress(_ text: Text) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            text
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outcome(systemImage: String, tint: Color, message: Text,
                         @ViewBuilder actions: () -> some View) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: systemImage)
                    .font(.system(size: 44))
                    .foregroundStyle(tint)
                message
                    .multilineTextAlignment(.center)
                actions()
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

/// What a new Mac's code says, before anything is sent to it.
private struct PairingPreview: View {
    @Bindable var flow: PairingFlow
    let payload: PairingPayload

    var body: some View {
        Form {
            Section("Mac") {
                LabeledContent("Name") { Text(verbatim: payload.macName) }
                LabeledContent("Address") {
                    Text(verbatim: "\(payload.username)@\(payload.address.hostname) (\(payload.address.kind.displayName))")
                        .multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("SSH Host Key")
                    Text(verbatim: payload.hostKey.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                TextField("This Device's Name", text: $flow.deviceName)
                    .autocorrectionDisabled()
            } header: {
                Text("This Device")
            } footer: {
                Text("The Mac shows this name when it asks whether to let this device in.")
            }
            Section {
                Button("Connect") { flow.connect() }
                    .disabled(!flow.canConnect)
            } footer: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = flow.secondsLeft(payload, at: context.date)
                    Text("The QR code expires in \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))). The Mac will ask you to approve this device and show a confirmation code.")
                }
            }
        }
    }
}

/// A Mac already added, whose code gives another address.
private struct NewAddressPreview: View {
    let flow: PairingFlow
    let machine: Machine
    let payload: PairingPayload

    var body: some View {
        Form {
            Section {
                LabeledContent("Saved Address") {
                    Text(verbatim: "\(machine.hostname) (\(machine.addressKind?.displayName ?? ""))")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("New Address") {
                    Text(verbatim: "\(payload.address.hostname) (\(payload.address.kind.displayName))")
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text(verbatim: machine.displayName)
            } footer: {
                Text("\(machine.displayName) is already in Machines. This device connects to the new address with the key it already has and the Mac's saved host key, and switches to it only if that works. The Mac doesn't need to approve it again.")
            }
            Section {
                Button("Use New Address") { flow.moveAddress() }
            }
        }
    }
}

/// The confirmation code, while the Mac's owner decides.
private struct WaitingForApproval: View {
    let macName: String
    let code: PairingConfirmationCode

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Approve on the Mac")
                    .font(.title2.weight(.semibold))
                Text("\(macName) asks whether to let this device in. Check that it shows the same confirmation code, then approve it there.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(verbatim: code.description)
                    .font(.system(size: 48, weight: .semibold, design: .monospaced))
                    .accessibilityLabel(Text(verbatim: code.digits.map(String.init).joined(separator: " ")))
                ProgressView()
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - The app's environment

extension PairingFlow.Environment {
    /// The device's Secure Enclave, the system's name lookup, Network
    /// framework connections and SSH.
    static func live(store: MachineStore) -> Self {
        let client = PairingClient(resolver: PairingAddressResolver(), dialer: NetworkPairingDialer(),
                                   makeDeviceKey: { try SecureEnclaveSSHKey.makeForThisDevice() }, checker: SSHPairedMacChecker())
        return Self(client: client, store: store, device: PairingDefaults.deviceInfo,
                    rememberDeviceName: { PairingDefaults.deviceName = $0 })
    }
}

/// What the app keeps for pairing in its own defaults: this installation's
/// ID, and the name last given to the device.
enum PairingDefaults {
    private static let deviceIDKey = "pairing.device-id"
    private static let deviceNameKey = "pairing.device-name"

    static var deviceInfo: PairingDeviceInfo {
        let defaults = UserDefaults.standard
        let id: UUID
        if let saved = defaults.string(forKey: deviceIDKey).flatMap(UUID.init(uuidString:)) {
            id = saved
        } else {
            id = UUID()
            defaults.set(id.uuidString, forKey: deviceIDKey)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        return PairingDeviceInfo(id: id, model: UIDevice.current.model, appVersion: "\(version) (\(build))")
    }

    /// The name last given, or the system's name for the device.
    static var deviceName: String {
        get { UserDefaults.standard.string(forKey: deviceNameKey) ?? UIDevice.current.name }
        set { UserDefaults.standard.set(newValue, forKey: deviceNameKey) }
    }
}
