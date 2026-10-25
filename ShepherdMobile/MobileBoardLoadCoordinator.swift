import Foundation
import ShepherdKit

/// Orders an unloaded Board's inert cache hydration before its lease can begin
/// network work. BoardView supplies the live lease and refresh closures.
@MainActor
enum MobileBoardLoadCoordinator {
    static func run(
        machine: Machine,
        cache: MobileAgentListCache,
        publishCachedSnapshot: @escaping @MainActor (AgentListCache.Snapshot?) -> Void,
        startLease: @escaping @MainActor () async -> Void,
        refresh: @escaping @MainActor () -> Void
    ) async {
        let snapshot = await cache.snapshot(for: machine)
        publishCachedSnapshot(snapshot)
        guard !Task.isCancelled else { return }
        async let lease: Void = startLease()
        refresh()
        await lease
    }
}
