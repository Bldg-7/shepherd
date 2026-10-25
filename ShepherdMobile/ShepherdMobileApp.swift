import SwiftUI
import ShepherdKit

/// Shepherd on iPhone and iPad: the machines, each one's board, and what a
/// pane shows — read over SSH, from the device itself (docs/mobile-design.md,
/// Phase 1). One window; Config/Info-iOS.plist keeps it to one scene.
@main struct ShepherdMobileApp: App {
    @State private var machineStore: MachineStore
    @State private var agentListCache: MobileAgentListCache

    init() {
        let store = MachineStore()
        _machineStore = State(initialValue: store)
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shepherd", isDirectory: true)
            .appendingPathComponent("AgentListCache", isDirectory: true)
        _agentListCache = State(initialValue: MobileAgentListCache(machineStore: store, directory: applicationSupport))
    }

    var body: some Scene {
        WindowGroup {
            MachinesView(machineStore: machineStore, agentListCache: agentListCache)
        }
    }
}
