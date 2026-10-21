#if os(macOS)
import AppKit
import SwiftUI

/// Add iPhone or iPad (SHPHRD-77, "화면 흐름"): the checks before a code
/// can be shown, the address it carries, the code, and then a device's
/// request with its confirmation code, the answer, and how the device's
/// first connection went. Everything it shows is `PairingCoordinator`'s
/// state; it starts when the page appears and stops when it goes, which
/// closes the listener and turns down a request still waiting.
struct PairDeviceView: View {
    let coordinator: PairingCoordinator
    /// Why no device can be added now, or nil when one can: the page stays,
    /// but shows no new code, with why in the code's place (see
    /// `PairingCoordinator.setUnavailable`).
    var unavailableReason: String? = nil
    let onBack: () -> Void

    @State private var copiedCommand = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(title: "Add iPhone or iPad", backTitle: "iPhone and iPad", backHelp: "Back to iPhone and iPad",
                               backAccessibilityIdentifier: "settings.pair.back", onBack: onBack)
            Form {
                switch coordinator.phase {
                case .request:
                    requestSection
                case .finishing, .finished:
                    resultSection
                case .preparing, .showingCode, .stopped:
                    checksSection
                    addressSection
                    codeSection
                }
            }
            .formStyle(.grouped)
            SettingsPageFooter()
        }
        // A container of its own, so that its identifier doesn't take the
        // place of its buttons'.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.pair.page")
        .background(WindowSharingGuard(isProtected: coordinator.phase == .showingCode))
        .onAppear { coordinator.start() }
        .onDisappear { coordinator.stop() }
        .onChange(of: unavailableReason, initial: true) { _, reason in
            coordinator.setUnavailable(reason)
        }
    }

    // MARK: - Checks

    private var checksSection: some View {
        Section("Before You Start") {
            remoteLoginRow
            if let running = coordinator.herdrIsRunning {
                if running {
                    status(.ok, "herdr is running on this Mac.", id: "settings.pair.herdr")
                } else {
                    status(.warning, "herdr isn't running on this Mac. Start it, or the device's first connection can't reach it.",
                           id: "settings.pair.herdr")
                }
            }
            switch coordinator.firewall {
            case .blocksAllIncoming?:
                status(.problem, "The firewall blocks all incoming connections, so no device can reach this Mac. Turn that off in System Settings › Network › Firewall › Options.",
                       id: "settings.pair.firewall")
            case .on?:
                status(.info, "The firewall is on. If macOS asks whether hrdrhrdrhrdr may accept incoming network connections, click Allow.",
                       id: "settings.pair.firewall")
            case .off?, .unknown?, nil:
                EmptyView()
            }
            if case .problem(let problem) = coordinator.authorizedKeys {
                status(.warning, "hrdrhrdrhrdr can't add the device's key itself: \(problem.description) You'll be given a command to run instead.",
                       id: "settings.pair.authorized-keys")
            }
            status(.info, "A Mac that's asleep can't be reached. To let a device see files in Desktop, Documents and Downloads, turn on full disk access for remote users in Remote Login's settings.",
                   id: "settings.pair.awake")
        }
    }

    @ViewBuilder
    private var remoteLoginRow: some View {
        switch coordinator.remoteLogin {
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking Remote Login…")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.pair.remote-login")
        case .on:
            HStack(alignment: .firstTextBaseline) {
                status(.ok, "Remote Login is on. Devices you add log in to this Mac over SSH; while it is on, anyone on your network can try to log in, but only allowed keys and passwords work.",
                       id: "settings.pair.remote-login")
                InfoButton(accessibilityLabel: "About Password Login",
                           explanation: "Remote Login also accepts your account's password from anyone who can reach this Mac. To accept only keys, such as the ones devices get here, put “PasswordAuthentication no” and “KbdInteractiveAuthentication no” in a file in /etc/ssh/sshd_config.d/.")
            }
        case .off:
            VStack(alignment: .leading, spacing: 8) {
                status(.problem, "Remote Login is off. A device logs in to this Mac over SSH, so turn on Remote Login in System Settings › General › Sharing, and leave it on while you use the device. This page checks again every two seconds.",
                       id: "settings.pair.remote-login")
                Button("Open Sharing Settings…") { NSWorkspace.shared.open(RemoteLoginSettings.url) }
                    .accessibilityIdentifier("settings.pair.open-sharing")
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                status(.warning, "Couldn't check Remote Login: \(message)", id: "settings.pair.remote-login")
                Button("Check Again") { coordinator.recheck() }
                    .accessibilityIdentifier("settings.pair.recheck")
            }
        }
    }

    private enum Severity {
        case ok, info, warning, problem

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle.fill"
            case .problem: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .ok: .green
            case .info: .secondary
            case .warning: .orange
            case .problem: .red
            }
        }
    }

    private func status(_ severity: Severity, _ text: LocalizedStringKey, id: String) -> some View {
        status(severity, Text(text), id: id)
    }

    private func status(_ severity: Severity, _ text: Text, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity.symbol)
                .foregroundStyle(severity.color)
                .accessibilityHidden(true)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: - Address

    private var addressSection: some View {
        Section {
            if !coordinator.hasLookedUpAddresses {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Looking for this Mac's addresses…")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.pair.addresses-loading")
            } else if coordinator.options.isEmpty {
                status(.problem, "There's no address a device could reach this Mac at. Connect this Mac to Wi-Fi or a wired network, or turn on Tailscale.",
                       id: "settings.pair.no-address")
            } else {
                ForEach(coordinator.options) { option in
                    addressRow(option)
                }
            }
            if let notice = coordinator.addressNotice {
                status(.info, Self.text(for: notice), id: "settings.pair.address-notice")
            }
        } header: {
            Text("Address")
        } footer: {
            Text("The QR code carries only the address chosen here. The device connects to this Mac at that address, now and later.")
                .foregroundStyle(.secondary)
        }
    }

    private func addressRow(_ option: PairingAddressOption) -> some View {
        let isSelected = coordinator.selectedOption?.id == option.id
        return Button {
            coordinator.select(option.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.title)
                    Text(verbatim: option.address.hostname)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text(Self.reach(of: option.kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(Self.identifier(for: option))
    }

    static func identifier(for option: PairingAddressOption) -> String {
        "settings.pair.address.\(option.kind.rawValue)" + (option.id.interfaceName.map { ".\($0)" } ?? "")
    }

    /// How far a kind of address reaches, under its value.
    static func reach(of kind: PairingAddressKind) -> LocalizedStringKey {
        switch kind {
        case .localName:
            "Only on the same Wi-Fi or wired network. Keeps working when the router gives this Mac another IP address."
        case .privateIPv4:
            "Only on the same network. If this IP address changes, scan a new QR code."
        case .tailscaleIPv4:
            "From anywhere, while both the device and this Mac are connected to Tailscale."
        case .tailscaleMagicDNS:
            "From anywhere while Tailscale is on. Needs Use Tailscale DNS turned on in Tailscale on the device."
        }
    }

    static func text(for notice: PairingCoordinator.AddressNotice) -> LocalizedStringKey {
        switch notice {
        case .switched(let lost, let chosen):
            "\(lost.displayName) can't be used anymore, so the QR code now carries \(chosen.displayName)."
        case .unavailable(let lost):
            "\(lost.displayName) can't be used anymore."
        }
    }

    // MARK: - Code

    @ViewBuilder
    private var codeSection: some View {
        Section("QR Code") {
            switch coordinator.phase {
            case .showingCode:
                if let code = coordinator.code {
                    shownCode(code)
                }
            case .stopped(let reason):
                status(.warning, Self.text(for: reason), id: "settings.pair.stopped")
                unavailableRow
                showButton("Show QR Code Again")
            default:
                // It says a new code is shown, which it isn't while one
                // can't be.
                if let decision = coordinator.lastDecision, coordinator.unavailableReason == nil {
                    lastDecisionRow(decision)
                }
                unavailableRow
                showButton("Show QR Code")
                Text("The code appears only when you ask for it. Anyone who sees it can ask to connect, but no device gets in until you approve it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Why no code can be shown now, if that is why.
    @ViewBuilder
    private var unavailableRow: some View {
        if let reason = coordinator.unavailableReason {
            status(.info, Text(verbatim: reason), id: "settings.pair.unavailable")
        }
    }

    private func showButton(_ title: LocalizedStringKey) -> some View {
        Button(title) { coordinator.showCode() }
            .disabled(!coordinator.canShowCode)
            .accessibilityIdentifier("settings.pair.show-code")
    }

    private func lastDecisionRow(_ decision: PairingCoordinator.LastDecision) -> some View {
        Group {
            switch decision {
            case .rejected(let name):
                status(.info, "You turned down “\(name)”. Here is a new QR code.", id: "settings.pair.last-decision")
            case .timedOut(let name):
                status(.info, "“\(name)” was turned down: no answer within a minute. Here is a new QR code.", id: "settings.pair.last-decision")
            case .cancelled(let name):
                status(.info, "“\(name)” cancelled its request or lost its connection, so nothing was added. Here is a new QR code.",
                       id: "settings.pair.last-decision")
            }
        }
    }

    private func shownCode(_ code: PairingCoordinator.ShownCode) -> some View {
        VStack(spacing: 10) {
            if let decision = coordinator.lastDecision {
                lastDecisionRow(decision)
            }
            if let image = PairingQRCodeCache.image(for: code.text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 232, height: 232)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement()
                    .accessibilityLabel(Text("QR code for \(code.option.address.hostname)"))
                    .accessibilityIdentifier("settings.pair.qr")
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text("Changes to a new code in \(Self.minutesAndSeconds(coordinator.secondsLeft ?? 0)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.pair.time-left")
            }
            Text("In hrdrhrdrhrdr on your iPhone or iPad, tap + in Machines, then Scan Mac's QR Code.")
                .font(.caption)
                .multilineTextAlignment(.center)
            status(.warning, "Anyone who can see your screen can see this code. Hide it before you share your screen or record it.",
                   id: "settings.pair.screen-warning")
            Button("Hide QR Code") { coordinator.hideCode() }
                .accessibilityIdentifier("settings.pair.hide-code")
        }
        .frame(maxWidth: .infinity)
    }

    static func minutesAndSeconds(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func text(for reason: PairingCoordinator.StopReason) -> LocalizedStringKey {
        switch reason {
        case .timeLimit:
            "QR codes were shown for ten minutes, so hrdrhrdrhrdr stopped listening for devices."
        case .tooManyFailures:
            "Too many requests that weren't right came in, so hrdrhrdrhrdr stopped listening for devices. If you didn't expect that, check what else is on your network."
        case .listenerFailed(let message):
            "hrdrhrdrhrdr couldn't listen for devices: \(message)"
        case .codeFailed(let message):
            "hrdrhrdrhrdr couldn't make a QR code: \(message)"
        }
    }

    // MARK: - Request

    @ViewBuilder
    private var requestSection: some View {
        if let request = coordinator.request {
            Section("Request") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("“\(request.request.deviceName)” (\(request.request.deviceModel)) wants to connect to this Mac.")
                        .font(.headline)
                        .accessibilityIdentifier("settings.pair.request.title")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Confirmation code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: request.confirmationCode.description)
                            .font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .accessibilityLabel(Text(verbatim: request.confirmationCode.description))
                            .accessibilityIdentifier("settings.pair.request.code")
                    }
                    Text("Check that the device shows the same code. Approve only a device you have in front of you.")
                        .fixedSize(horizontal: false, vertical: true)
                    if request.laterRequests > 0 {
                        status(.problem, "Another device also asked to connect with this QR code. If this request isn't from your device, turn it down.",
                               id: "settings.pair.request.another")
                    }
                    Text("From \(request.remote.description) · \(request.addressKind.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = request.authenticationError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("settings.pair.request.auth-error")
                    }
                    HStack {
                        Button("Reject") { coordinator.reject() }
                            .accessibilityIdentifier("settings.pair.reject")
                        Spacer()
                        if request.isAuthenticating {
                            ProgressView().controlSize(.small)
                        }
                        Button("Approve…") { Task { await coordinator.approve() } }
                            .disabled(request.isAuthenticating)
                            .accessibilityIdentifier("settings.pair.approve")
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("If you don't answer, it's turned down in \(Self.minutesAndSeconds(secondsToAnswer(request))).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func secondsToAnswer(_ request: PairingCoordinator.Request) -> Int {
        let limit = request.isAuthenticating ? PairingCoordinator.authenticationLimit : PairingCoordinator.approvalTimeout
        return max(0, Int((limit - coordinator.now.timeIntervalSince(request.receivedAt)).rounded(.up)))
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        if let finished = coordinator.finished {
            Section("Result") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.headline(for: finished, isFinished: coordinator.phase == .finished))
                        .font(.headline)
                        .accessibilityIdentifier("settings.pair.result.title")
                    keyRow(finished.key)
                    if coordinator.phase == .finishing {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for “\(finished.device.name)” to connect…")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.pair.result.waiting")
                    } else if let report = finished.report {
                        if report.sshConnected {
                            status(.ok, "It logged in over SSH.", id: "settings.pair.result.ssh")
                        } else {
                            status(.problem, "It couldn't log in over SSH. Check that Remote Login lets your user in: System Settings › General › Sharing › Remote Login ⓘ.",
                                   id: "settings.pair.result.ssh")
                        }
                        if report.herdrReached {
                            status(.ok, "It reached herdr.", id: "settings.pair.result.herdr")
                        } else if report.sshConnected {
                            status(.problem, "It couldn't reach herdr. Start herdr on this Mac.", id: "settings.pair.result.herdr")
                        }
                        if let failure = report.failure, !failure.isEmpty {
                            Text("The device said: \(failure)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if finished.reportMissing {
                        status(.warning, "The device didn't say how its first connection went.", id: "settings.pair.result.no-report")
                    }
                    if let error = finished.recordError {
                        status(.warning, "It couldn't be added to the list of devices: \(error)", id: "settings.pair.result.record-error")
                    }
                    if coordinator.phase == .finished {
                        unavailableRow
                        HStack {
                            Button("Add Another Device") {
                                coordinator.reset()
                                coordinator.showCode()
                            }
                            .disabled(coordinator.unavailableReason != nil)
                            .accessibilityIdentifier("settings.pair.another")
                            Spacer()
                            Button("Back to iPhone and iPad", action: onBack)
                                .accessibilityIdentifier("settings.pair.result.back")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyRow(_ key: PairingCoordinator.KeyOutcome) -> some View {
        switch key {
        case .added:
            status(.ok, "Its key was added to ~/.ssh/authorized_keys.", id: "settings.pair.result.key")
        case .alreadyPresent:
            status(.ok, "Its key was already in ~/.ssh/authorized_keys.", id: "settings.pair.result.key")
        case .notWritten(let problem, let command):
            VStack(alignment: .leading, spacing: 8) {
                status(.warning, "Its key wasn't added: \(problem) Run this in Terminal to let it in:", id: "settings.pair.result.key")
                Text(verbatim: command)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("settings.pair.result.command")
                Button(copiedCommand ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCommand = true
                }
            }
        }
    }

    static func headline(for finished: PairingCoordinator.Finished, isFinished: Bool) -> LocalizedStringKey {
        let name = finished.device.name
        if !isFinished { return "You approved “\(name)”." }
        if finished.report?.sshConnected == true && finished.report?.herdrReached == true {
            return "“\(name)” can now connect to this Mac."
        }
        return "“\(name)” was added, but its first connection didn't work."
    }
}

/// The last code's image, so a page that redraws every second doesn't make
/// it again.
@MainActor enum PairingQRCodeCache {
    private static var last: (text: String, image: CGImage)?

    static func image(for text: String) -> CGImage? {
        if let last, last.text == text { return last.image }
        guard let image = PairingQRCode.image(for: text) else { return nil }
        last = (text, image)
        return image
    }
}

/// Keeps the window the page is in out of screen captures that honour it
/// (`NSWindow.sharingType = .none`) while a code is shown, and asks for the
/// window's own sharing type back afterwards. Not every way of capturing the
/// screen honours it, which is why the page also says to hide the code.
/// macOS 26 keeps a window that has been on screen at `.none` once it is set
/// there, whatever is asked after (a window not yet on screen does go back),
/// so Settings stays out of captures until it closes.
struct WindowSharingGuard: NSViewRepresentable {
    let isProtected: Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.isProtected = isProtected
    }

    static func dismantleNSView(_ view: GuardView, coordinator: ()) {
        view.isProtected = false
    }

    final class GuardView: NSView {
        var isProtected = false {
            didSet { apply() }
        }
        private weak var protectedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            if isProtected, let window {
                guard protectedWindow !== window else { return }
                release()
                WindowSharingProtection.protect(window)
                protectedWindow = window
            } else {
                release()
            }
        }

        private func release() {
            if let protectedWindow { WindowSharingProtection.release(protectedWindow) }
            protectedWindow = nil
        }
    }
}

/// Counts the guards protecting each window, since SwiftUI may make more
/// than one, and puts a window's own sharing type back when the last goes.
@MainActor enum WindowSharingProtection {
    private static var held: [ObjectIdentifier: (count: Int, original: NSWindow.SharingType)] = [:]

    static func protect(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let entry = held[id] {
            held[id] = (entry.count + 1, entry.original)
        } else {
            held[id] = (1, window.sharingType)
            window.sharingType = .none
        }
    }

    static func protects(_ window: NSWindow) -> Bool {
        held[ObjectIdentifier(window)] != nil
    }

    static func release(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let entry = held[id] else { return }
        if entry.count > 1 {
            held[id] = (entry.count - 1, entry.original)
        } else {
            held[id] = nil
            window.sharingType = entry.original
        }
    }
}
#endif
