import Foundation
import Combine

@MainActor struct HcWindowActions {
    let canLaunch: Bool; let canClose: Bool; let canSwitch: Bool; let canSettings: Bool
    let closeTitle: String
    let launch: () -> Void; let close: () -> Void; let switcher: () -> Void; let settings: () -> Void
    var launchCurrentWorkspace: (() -> Void)? = nil
}

/// One main-window owner. Commands explicitly observe objectWillChange: a
/// nested menu View reading an @Observable singleton can remain the initial
/// disabled snapshot in SwiftUI's Commands host. This is UI dispatch only,
/// never authorization; models still check current origin/version/lifetime.
@MainActor final class HcWindowCommandState: ObservableObject {
    enum Action { case launch, launchCurrentWorkspace, close, switcher, settings }
    static let shared = HcWindowCommandState()
    @Published private(set) var actions: HcWindowActions?
    private var owner: UUID?
    func claim(_ id: UUID, actions: HcWindowActions) { owner = id; self.actions = actions }
    func update(_ id: UUID, actions: HcWindowActions) { if owner == id { self.actions = actions } }
    func release(_ id: UUID) { if owner == id { owner = nil; actions = nil } }
    @discardableResult func perform(_ action: Action) -> Bool {
        guard let actions else { return false }
        switch action {
        case .launch: guard actions.canLaunch else { return false }; actions.launch()
        case .launchCurrentWorkspace:
            guard actions.canLaunch else { return false }
            (actions.launchCurrentWorkspace ?? actions.launch)()
        case .close: guard actions.canClose else { return false }; actions.close()
        case .switcher: guard actions.canSwitch else { return false }; actions.switcher()
        case .settings: guard actions.canSettings else { return false }; actions.settings()
        }
        return true
    }
}
