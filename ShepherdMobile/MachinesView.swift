import SwiftUI
import ShepherdKit

/// The machines, each a herdr reached over SSH. Tapping one shows its
/// board; the plus adds one, by scanning the QR code a Mac shows (the Mac
/// approves this device, and its board opens once it is added) or by hand.
/// The About menu has the privacy policy, which opens in the browser, and
/// the open-source licenses.
struct MachinesView: View {
    let machineStore: MachineStore
    @State private var path = NavigationPath()
    @State private var isAdding = false
    @State private var isPairing = false
    /// A Mac just paired, whose board opens once the sheet has gone.
    @State private var pairedMachine: Machine?
    @State private var isShowingLicenses = false

    private static let privacyPolicy = URL(string: "https://bldg-7.github.io/shepherd/privacy/")!

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if machineStore.allMachines.isEmpty {
                    ContentUnavailableView {
                        Label("No Machines", systemImage: "server.rack")
                    } description: {
                        Text("Add a machine running herdr to see its agents.")
                    } actions: {
                        Button("Scan Mac's QR Code") { isPairing = true }
                            .buttonStyle(.borderedProminent)
                        Button("Add Machine Manually") { isAdding = true }
                    }
                } else {
                    List {
                        ForEach(machineStore.allMachines) { machine in
                            NavigationLink(value: machine) {
                                MachineRow(machine: machine)
                            }
                        }
                        .onDelete { offsets in
                            for machine in offsets.map({ machineStore.allMachines[$0] }) {
                                machineStore.removeMachine(machine)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Machines")
            .navigationDestination(for: Machine.self) { machine in
                BoardView(machine: machine, machineStore: machineStore)
            }
            .navigationDestination(for: PaneDestination.self) { destination in
                ConversationView(destination: destination, machineStore: machineStore)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Link(destination: Self.privacyPolicy) {
                            Label("Privacy Policy", systemImage: "hand.raised")
                        }
                        Button {
                            isShowingLicenses = true
                        } label: {
                            Label("Open Source Licenses", systemImage: "doc.text")
                        }
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isPairing = true
                        } label: {
                            Label("Scan Mac's QR Code", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            isAdding = true
                        } label: {
                            Label("Add Machine Manually", systemImage: "keyboard")
                        }
                    } label: {
                        Label("Add Machine", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                AddMachineView(machineStore: machineStore)
            }
            .sheet(isPresented: $isPairing, onDismiss: openPairedMachine) {
                PairingSheet(machineStore: machineStore) { machine in
                    pairedMachine = machine
                    isPairing = false
                }
            }
            .sheet(isPresented: $isShowingLicenses) {
                OpenSourceLicensesView()
            }
        }
    }

    private func openPairedMachine() {
        guard let machine = pairedMachine else { return }
        pairedMachine = nil
        path = NavigationPath()
        path.append(machine)
    }
}

private struct MachineRow: View {
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(machine.displayName)
            Text(verbatim: target)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var target: String {
        let host = "\(machine.username)@\(machine.hostname)" + (machine.port == 22 ? "" : ":\(machine.port)")
        return machine.sessionName.isEmpty ? host : "\(host) · \(machine.sessionName)"
    }
}
