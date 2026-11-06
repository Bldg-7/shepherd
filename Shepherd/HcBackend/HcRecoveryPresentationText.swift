import Foundation

/// Recovery descriptions are facts/bookkeeping, never dispatch authority.
nonisolated enum HcRecoveryPresentationText {
    static func title(_ record: CoreWorkspaceRecovery.Record) -> String {
        if record.kind == .launch { return "Launch" }
        return record.paneID == nil ? "Close tab" : "Close pane"
    }
    static func stop(_ state: CoreWorkspaceRecovery.Stop) -> String {
        switch state {
        case .pending: return "No stop dispatched"
        case .inFlight: return "Stop in flight — do not retry"
        case .uncertain: return "Stop unconfirmed — read/review only"
        case .confirmed: return "Ended confirmed"
        case .shared: return "Program retained: shared view"
        case .foreign: return "Program retained: different origin"
        }
    }
    static func explanation(_ record: CoreWorkspaceRecovery.Record, canApplyLayout: Bool) -> String {
        if record.layout == .confirmed {
            if record.kind == .launch { return "The known run receipt is bound in the layout. Later edits will not be undone. The program will not be restarted." }
            if record.targets.isEmpty { return "The view layout action is confirmed. No program termination was requested. Later edits will not be undone." }
            return record.complete
                ? "The layout is confirmed. Program outcomes are listed separately; retained shared programs were not stopped. Nothing will be replayed."
                : "The layout is confirmed, but program outcomes remain unconfirmed. Review uses fresh reads only; it never sends another stop."
        }
        if canApplyLayout {
            if record.kind == .launch { return "A successful run receipt is saved and its original pane is still unbound. You can explicitly bind that exact reference with one new CAS attempt." }
            return record.paneID == nil
                ? "The original tab still has its reviewed members. You can explicitly close those views with one new layout CAS. No program action will be sent."
                : "The original pane still has its reviewed reference. You can explicitly close only that view with one new layout CAS. No program action will be sent."
        }
        return "There is no safe layout reapplication for this record: its outcome is unknown or its target fields changed. Inspect canonical terminals separately; operation labels are not ownership proof."
    }
}
