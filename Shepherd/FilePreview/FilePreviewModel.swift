import Foundation
import Observation

struct FilePreviewRequest: Identifiable {
    let id = UUID()
    let machine: Machine
    let paneID: String
    let terminalID: String
    let directory: String?
    let nestedMachine: Bool
    let rawLink: String

    init(machine: Machine, pane: AgentSummary, link: String) {
        self.machine = machine; paneID = pane.paneID; terminalID = pane.terminalID
        directory = pane.workingDirectory; nestedMachine = pane.herdrMachine != nil; rawLink = link
    }

    func following(_ link: String, directory: String) -> Self {
        Self(machine: machine, paneID: paneID, terminalID: terminalID,
             directory: directory, nestedMachine: nestedMachine, rawLink: link)
    }

    private init(machine: Machine, paneID: String, terminalID: String, directory: String?, nestedMachine: Bool, rawLink: String) {
        self.machine = machine; self.paneID = paneID; self.terminalID = terminalID
        self.directory = directory; self.nestedMachine = nestedMachine; self.rawLink = rawLink
    }
}

@MainActor @Observable final class FilePreviewModel {
    enum State { case loading, loaded(FilePreviewDocument), failed(String) }
    private(set) var state = State.loading
    private(set) var link: FilePreviewLink?
    private var generation = UUID()

    func load(_ request: FilePreviewRequest, store: MachineStore) async {
        let epoch = UUID()
        generation = epoch
        state = .loading; link = nil
        let reader = FilePreviewReader()
        do {
            try Task.checkCancellation()
            let machine = try store.currentMachine(matching: request.machine)
            guard !request.nestedMachine else { throw FilePreviewError.nestedMachine }
            let resolved = try FilePreviewLink.resolve(request.rawLink, directory: request.directory, hostname: machine.hostname,
                additionalHosts: machine.isLocal ? FilePreviewLink.localHostAliases : [])
            link = resolved
            // Local previews must not even look up a remote credential.
            // An unpinned endpoint is not a reason to prompt for a credential.
            if !machine.isLocal && machine.pinnedHostKeyFingerprint == nil { throw FilePreviewError.needsHostKey }
            let secret = machine.isLocal ? nil : try store.secret(for: machine)
            let data = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await reader.read(path: resolved.path, machine: machine, secret: secret) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw FilePreviewError.timedOut
                    }
                    defer { group.cancelAll() }
                    do {
                        guard let result = try await group.next() else { throw CancellationError() }
                        return result
                    } catch {
                        // Close before the group drains an uncooperative SSH
                        // read; preserve the timeout error instead of racing
                        // it with the read's connection-closed error.
                        await reader.cancel()
                        throw error
                    }
                }
            } onCancel: { Task { await reader.cancel() } }
            try Task.checkCancellation()
            _ = try store.currentMachine(matching: request.machine)
            guard generation == epoch else { return }
            state = .loaded(try FilePreviewDocument(data: data, path: resolved.path))
        } catch {
            await reader.cancel()
            guard generation == epoch, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
