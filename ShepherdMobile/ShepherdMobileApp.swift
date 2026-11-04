import SwiftUI
import ShepherdKit

/// Shepherd on iPhone and iPad: the machines, each one's board, and what a
/// pane shows — read over SSH, from the device itself (docs/mobile-design.md,
/// Phase 1). One window; Config/Info-iOS.plist keeps it to one scene.
@main struct ShepherdMobileApp: App {
    @State private var machineStore: MachineStore
    @State private var cache: HcMobileCache

    init() {
        let store = MachineStore()
        _machineStore = State(initialValue: store)
        let cache = HcMobileCache()
        store.connectionWillInvalidate = { cache.retire($0) }
        store.machineWillRemove = { cache.remove($0) }
        _cache = State(initialValue: cache)
    }

    var body: some Scene {
        WindowGroup {
            MachinesView(machineStore: machineStore, cache: cache)
        }
    }
}
