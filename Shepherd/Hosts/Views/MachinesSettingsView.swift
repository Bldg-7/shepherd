import SwiftUI

/// Machine management: Settings, presented as a sheet over the main window
/// by `ContentView`. Exactly one Machine is active at a time —
/// `ContentView`'s sidebar always reflects `machineStore.activeMachine`, so
/// switching here is immediate.
struct MachinesSettingsView: View {
    let machineStore: MachineStore

    @State private var isAddingMachine = false
    @State private var machineBeingEdited: Machine?
    #if os(macOS)
    @State private var showsNotifications = false
    @State private var showsExperimentalFeatures = false
    @State private var hoveredMachineID: UUID?
    @State private var passwordManagerWindowID: UUID

    init(machineStore: MachineStore, passwordManagerWindowID: UUID = UUID()) {
        self.machineStore = machineStore
        _passwordManagerWindowID = State(initialValue: passwordManagerWindowID)
    }
    #endif
    /// The machine whose removal is waiting for the person to confirm it.
    /// Removing a machine deletes its credential from the Keychain, and a
    /// key Shepherd generated exists nowhere else, so it is never removed
    /// on a single click or swipe.
    @State private var machinePendingRemoval: Machine?
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(SoftwareUpdater.self) private var softwareUpdater: SoftwareUpdater?
    #endif

    var body: some View {
        // Detail pages stay inside this sheet, using the same navigation
        // treatment as Add Machine rather than stacking another sheet.
        ZStack {
            if let machine = machineBeingEdited {
                AddMachineView(machineStore: machineStore, editingMachine: machine) {
                    withAnimation(Self.pageAnimation) { machineBeingEdited = nil }
                }
                .id(machine.id)
                .transition(.move(edge: .trailing))
            } else if isAddingMachine {
                AddMachineView(machineStore: machineStore) {
                    withAnimation(Self.pageAnimation) { isAddingMachine = false }
                }
                .transition(.move(edge: .trailing))
            } else if showsNotifications {
                NotificationSettingsView {
                    withAnimation(Self.pageAnimation) { showsNotifications = false }
                }
                .transition(.move(edge: .trailing))
            } else if showsExperimentalFeatures {
                ExperimentalFeaturesSettingsView(machineStore: machineStore,
                                                 passwordManagerWindowID: passwordManagerWindowID) {
                    withAnimation(Self.pageAnimation) { showsExperimentalFeatures = false }
                }
                .transition(.move(edge: .trailing))
            } else {
                machineList
                    .transition(.move(edge: .leading))
            }
        }
        .clipped()
        // One size for all pages, so the sheet doesn't jump in size as
        // they change; the form scrolls in the rare case it needs more.
        // Fixed rather than ideal-sized, too: the form's ideal width is as
        // wide as the authorized_keys command it shows, a single line with
        // no spaces to wrap at for most of its length.
        .frame(width: 540, height: 620)
        .onAppear {
            // ContentView can hand this window an already-claimed startup
            // onboarding lease. Route that explicit request to the detail page.
            if ShepherdBrowserFeature.shared.isEnabled,
               ShepherdBrowserFeature.shared.passwordManagers.presentationOwner == passwordManagerWindowID {
                isAddingMachine = false
                machineBeingEdited = nil
                showsExperimentalFeatures = true
            }
        }
        .onDisappear {
            // Also covers dismissal before the requested detail page mounts.
            ShepherdBrowserFeature.shared.passwordManagers.endVisit(owner: passwordManagerWindowID)
        }
        .confirmationDialog(removalTitle, isPresented: isConfirmingRemoval, presenting: machinePendingRemoval) { machine in
            removalActions(for: machine)
        } message: { _ in
            Text(removalMessage)
        }
    }

    private static let pageAnimation: Animation = .easeInOut(duration: 0.25)

    /// Laid out the way System Settings lays out a list of things: one
    /// grouped section of rows, each with its own actions, and the add
    /// button under the group. A sheet has no toolbar to put an add button
    /// in, so it goes with the list it adds to; the way out of the sheet
    /// goes along the bottom edge, where the Add Machine page has its
    /// Cancel and Add.
    private var machineList: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(machineStore.allMachines) { machine in
                        macRow(for: machine)
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("The active machine's panes and agents are listed in the main window.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Machine…") {
                            withAnimation(Self.pageAnimation) { isAddingMachine = true }
                        }
                    }
                }
                Section {
                    Button {
                        withAnimation(Self.pageAnimation) { showsNotifications = true }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bell")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text("Notifications")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.notifications")
                    Button {
                        withAnimation(Self.pageAnimation) { showsExperimentalFeatures = true }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "flask")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text("Experimental Features")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.experimental-features")
                }
                if let softwareUpdater, softwareUpdater.isAvailable {
                    updatesSection(softwareUpdater)
                }
                versionSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// Shepherd's own updates: whether Sparkle checks on its own, and a way
    /// to check right away. The version running has its own section, under
    /// this one.
    private func updatesSection(_ updater: SoftwareUpdater) -> some View {
        @Bindable var updater = updater
        return Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
            HStack {
                Spacer()
                Button("Check Now") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    /// The version and build running, in every build: a debug build has no
    /// Updates section, and its version says it is one, so a build from
    /// Xcode can be told from a release. Selectable, to copy into a report.
    private var versionSection: some View {
        Section {
            LabeledContent("Version") {
                Text(verbatim: AppVersion.current.displayString)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings.version")
            }
        }
    }

    /// A row with its actions spelled out as buttons. On macOS nothing
    /// suggests that a whole row is clickable, and the list's other gesture
    /// — swiping to delete — isn't there with a mouse at all.
    @ViewBuilder
    private func macRow(for machine: Machine) -> some View {
        let isActive = machineStore.activeMachineID == machine.id
        HStack(spacing: 10) {
            Image(systemName: machine.isLocal ? "laptopcomputer" : "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.displayName)
                Text(subtitle(for: machine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(Self.pageAnimation) { machineBeingEdited = machine }
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit Machine")
            .accessibilityLabel("Edit Machine")
            .accessibilityIdentifier("settings.machine.edit.\(machine.id.uuidString)")
            .opacity(!machine.isLocal && hoveredMachineID == machine.id ? 1 : 0)
            .disabled(machine.isLocal || hoveredMachineID != machine.id)
            .accessibilityHidden(machine.isLocal || hoveredMachineID != machine.id)
            // Every row keeps this slot, the built-in entry included (it
            // can't be removed), so the buttons before it line up down the
            // list.
            Button {
                machinePendingRemoval = machine
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(machine.displayName)…")
            .opacity(!machine.isLocal && hoveredMachineID == machine.id ? 1 : 0)
            .disabled(machine.isLocal || hoveredMachineID != machine.id)
            .accessibilityHidden(machine.isLocal || hoveredMachineID != machine.id)
            Group {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.tint)
                } else {
                    Button("Make Active") { machineStore.activeMachineID = machine.id }
                }
            }
            .frame(minWidth: 100, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredMachineID = machine.id }
            else if hoveredMachineID == machine.id { hoveredMachineID = nil }
        }
        .contextMenu {
            if !machine.isLocal {
                Button("Edit Machine", systemImage: "pencil") {
                    withAnimation(Self.pageAnimation) { machineBeingEdited = machine }
                }
                Button("Remove…", role: .destructive) {
                    machinePendingRemoval = machine
                }
            }
        }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { machinePendingRemoval != nil },
            set: { isShowing in
                if !isShowing { machinePendingRemoval = nil }
            }
        )
    }

    private var removalTitle: Text {
        Text("Remove \u{201C}\(machinePendingRemoval?.displayName ?? "")\u{201D}?")
    }

    private var removalMessage: LocalizedStringKey {
        "Its SSH key or password is deleted from the Keychain. A key Shepherd generated can't be recovered: adding the machine again means authorizing a new key on it."
    }

    @ViewBuilder
    private func removalActions(for machine: Machine) -> some View {
        Button("Remove", role: .destructive) {
            machineStore.removeMachine(machine)
        }
        Button("Cancel", role: .cancel) {}
    }

    private func subtitle(for machine: Machine) -> String {
        if machine.isLocal {
            return String(localized: "This Mac's own herdr session")
        }
        let base = "\(machine.username)@\(machine.hostname):\(machine.port)"
        return machine.sessionName.isEmpty ? base : "\(base) · \(machine.sessionName)"
    }
}

#Preview {
    MachinesSettingsView(machineStore: MachineStore())
}
