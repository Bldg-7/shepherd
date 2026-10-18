import SwiftUI
import ShepherdKit

/// The machines, each a herdr reached over SSH. Tapping one shows its
/// board; the plus adds one.
struct MachinesView: View {
    let machineStore: MachineStore
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Group {
                if machineStore.allMachines.isEmpty {
                    ContentUnavailableView {
                        Label("No Machines", systemImage: "server.rack")
                    } description: {
                        Text("Add a machine running herdr to see its agents.")
                    } actions: {
                        Button("Add Machine") { isAdding = true }
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
                PaneOutputView(destination: destination, machineStore: machineStore)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAdding = true
                    } label: {
                        Label("Add Machine", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAdding) {
                AddMachineView(machineStore: machineStore)
            }
        }
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
