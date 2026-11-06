#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Same row-to-terminal text interaction as the original board, but uses real
/// UUIDs in 3rdr-workspace-v1. These are NOT hc terminal IDs or agent authority.
@MainActor enum HcWorkspaceItemDrag {
    nonisolated static let typeIdentifier = "com.bldg-7.shepherd.hc-workspace-item"
    private struct Drag {
        let reference: HcWorkspaceRowReference
        let machine: Machine.ConnectionIdentity
        let sourceIsCurrent: @MainActor () -> Bool
    }
    private static var dragged: Drag?

    static func provider(kind: HcWorkspaceRowReference.Kind, id: UUID, model: HcWorkspaceModel,
                         machine: Machine?, store: MachineStore?,
                         isCurrentModel: @escaping @MainActor (HcWorkspaceModel) -> Bool) -> NSItemProvider? {
        guard isCurrentModel(model), let machine, let store, model.state == .connected, model.workspace?.canWrite == true, let core = model.coreID,
              let epoch = model.workspace?.epoch, let snapshot = model.workspace?.snapshot,
              let document = snapshot.document, store.activeMachineID == machine.id,
              store.isCurrentConnection(machine) else { return nil }
        let reference = HcWorkspaceRowReference(kind:kind,id:id,coreID:core,version:snapshot.version,
            terminal:kind == .pane ? document.pane(id)?.terminal : nil)
        guard reference.pasteText(reference.text,coreID:core,version:snapshot.version,document:document) != nil else { return nil }
        dragged = Drag(reference:reference,machine:machine.connectionIdentity,sourceIsCurrent:{ [weak model] in
            guard let model else { return false }
            return isCurrentModel(model) && model.state == .connected && model.workspace?.canWrite == true && model.workspace?.epoch == epoch && model.coreID == core
                && model.workspace?.snapshot?.version == snapshot.version
                && store.activeMachineID == machine.id && store.isCurrentConnection(machine)
        })
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier:typeIdentifier,visibility:.ownProcess) { done in done(Data(),nil); return nil }
        let bytes = Data(reference.text.utf8)
        provider.registerDataRepresentation(forTypeIdentifier:UTType.utf8PlainText.identifier,visibility:.all) { done in done(bytes,nil); return nil }
        return provider
    }

    static func terminalDrop(model: HcWorkspaceModel, machine: Machine, store: MachineStore,
                             targetIsCurrent: @escaping @MainActor () -> Bool,
                             onTargetChange: @escaping (Bool) -> Void) -> TerminalTextDrop {
        TerminalTextDrop(type:NSPasteboard.PasteboardType(typeIdentifier),text:{ text in
            guard targetIsCurrent(), let dragged, dragged.sourceIsCurrent(),
                  dragged.machine == machine.connectionIdentity, store.activeMachineID == machine.id,
                  store.isCurrentConnection(machine), model.state == .connected, model.workspace?.canWrite == true, let core = model.coreID,
                  let snapshot = model.workspace?.snapshot, let document = snapshot.document else { return nil }
            return dragged.reference.pasteText(text,coreID:core,version:snapshot.version,document:document)
        },onTargetChange:onTargetChange)
    }
}
#endif
