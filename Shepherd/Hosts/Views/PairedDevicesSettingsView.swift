#if os(macOS)
import AppKit
import SwiftUI

/// The iPhone and iPad page of Settings (SHPHRD-77): the devices this Mac
/// let in by QR code, each removable, a way to add another, and what
/// happened on the pairing page. Adding opens `PairDeviceView` in place of
/// this page, as this page opened in place of Machines.
struct PairedDevicesSettingsView: View {
    let model: PairedDevicesModel
    /// A new coordinator for each visit to the Add page.
    let makeCoordinator: () -> PairingCoordinator
    let onBack: () -> Void

    @State private var coordinator: PairingCoordinator?
    @State private var pendingRemoval: PairedDevicesModel.Row?
    @State private var copiedLine = false

    static let historyShown = 50
    private static let pageAnimation: Animation = .easeInOut(duration: 0.25)

    var body: some View {
        ZStack {
            if let coordinator {
                PairDeviceView(coordinator: coordinator) {
                    withAnimation(Self.pageAnimation) { self.coordinator = nil }
                    model.reload()
                }
                .transition(.move(edge: .trailing))
            } else {
                list
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
    }

    private var list: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: "iPhone and iPad", backAccessibilityIdentifier: "settings.devices.back", onBack: onBack)
            Form {
                Section {
                    if let error = model.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if model.rows.isEmpty {
                        Text("No iPhone or iPad can connect to this Mac yet.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.devices.empty")
                    }
                    ForEach(model.rows) { row in
                        deviceRow(row)
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("A device added here logs in to this Mac over Remote Login (SSH) with a key that never leaves the device.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Device…") {
                            withAnimation(Self.pageAnimation) { coordinator = makeCoordinator() }
                        }
                        .accessibilityIdentifier("settings.devices.add")
                    }
                }
                if let failure = model.removalFailure {
                    removalFailureSection(failure)
                }
                Section("History") {
                    if model.history.isEmpty {
                        Text("Nothing yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.history.prefix(Self.historyShown)) { entry in
                        historyRow(entry)
                    }
                }
            }
            .formStyle(.grouped)
            SettingsPageFooter()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.devices.page")
        .onAppear { model.reload() }
        .confirmationDialog(removalTitle, isPresented: isConfirmingRemoval, presenting: pendingRemoval) { row in
            Button("Remove", role: .destructive) { model.remove(row) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its key is taken out of ~/.ssh/authorized_keys, so it can't log in again. A connection it has open now isn't closed: to end one, turn Remote Login off and on again.")
        }
    }

    private func deviceRow(_ row: PairedDevicesModel.Row) -> some View {
        let device = row.device
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: device.model.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text("\(device.model) · added \(device.addedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: device.keyFingerprint)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                switch row.status {
                case .inFile:
                    EmptyView()
                case .notInFile:
                    Label("Not in ~/.ssh/authorized_keys: this device can't log in.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.devices.not-in-file.\(device.id)")
                case .unknown:
                    Label("~/.ssh/authorized_keys couldn't be read.", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                pendingRemoval = row
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(device.name)…")
            .accessibilityLabel("Remove \(device.name)…")
            .accessibilityIdentifier("settings.devices.remove.\(device.id)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.devices.row.\(device.id)")
    }

    private func removalFailureSection(_ failure: PairedDevicesModel.RemovalFailure) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("“\(failure.deviceName)” couldn't be removed: \(failure.message)", systemImage: "exclamationmark.triangle")
                Text("Take this line out of ~/.ssh/authorized_keys yourself, then remove the device here again:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: failure.line)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(copiedLine ? "Copied" : "Copy Line") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(failure.line, forType: .string)
                        copiedLine = true
                    }
                    Spacer()
                    Button("OK") {
                        model.removalFailure = nil
                        copiedLine = false
                    }
                }
            }
        }
        .accessibilityIdentifier("settings.devices.removal-failure")
    }

    private func historyRow(_ entry: PairingAuditEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.describe(entry))
            Spacer()
            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// One line of history.
    static func describe(_ entry: PairingAuditEntry) -> String {
        let name = entry.deviceName ?? String(localized: "A device")
        let from = entry.remoteAddress ?? "?"
        switch entry.event {
        case .requested:
            return String(localized: "“\(name)” asked to connect, from \(from).")
        case .requestAfterUse:
            return String(localized: "Another device asked to connect with a QR code already used, from \(from).")
        case .approved:
            return String(localized: "You approved “\(name)”.")
        case .rejected:
            return String(localized: "You turned down “\(name)”.")
        case .timedOut:
            return String(localized: "“\(name)” was turned down: no answer within a minute.")
        case .cancelled:
            return String(localized: "“\(name)” cancelled its request or lost its connection before an answer.")
        case .keyAdded:
            return String(localized: "Added the key of “\(name)” to ~/.ssh/authorized_keys.")
        case .keyAlreadyPresent:
            return String(localized: "The key of “\(name)” was already in ~/.ssh/authorized_keys.")
        case .keyNotWritten:
            return String(localized: "The key of “\(name)” couldn't be written to ~/.ssh/authorized_keys.")
        case .connectionChecked:
            return entry.detail?.hasPrefix("ssh=true herdr=true") == true
                ? String(localized: "“\(name)” logged in over SSH and reached herdr.")
                : String(localized: "“\(name)” couldn't finish its first connection.")
        case .connectionNotReported:
            return String(localized: "“\(name)” didn't report its first connection.")
        case .tooManyFailures:
            return String(localized: "Stopped listening for devices after too many requests that weren't right.")
        case .removed:
            return String(localized: "Removed “\(name)” and its key.")
        case .removedNotInFile:
            return String(localized: "Removed “\(name)”; its key was no longer in ~/.ssh/authorized_keys.")
        }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var removalTitle: Text {
        Text("Remove “\(pendingRemoval?.device.name ?? "")”?")
    }
}
#endif
