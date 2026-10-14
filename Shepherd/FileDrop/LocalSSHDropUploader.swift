import Foundation

#if os(macOS)
import Darwin

/// Uploads to a pane on one of this Mac's herdr machines. Shepherd has no
/// credential of its own for those — herdr reaches them with this Mac's
/// `ssh` and its keys — so the upload goes the same way: `ssh` runs
/// `TerminalDropPaste.receiveScript` there, reading the file itself as its
/// standard input. Each file is one `ssh`; there is no connection to close.
nonisolated struct LocalSSHDropUploader: TerminalDropUploading {
    let machine: HerdrMachine

    func upload(_ file: TerminalDropFile, batch: String, progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        guard TerminalDropPaste.isUsableTarget(machine.target) else { throw TerminalDropError.unusableTarget }
        let receive = TerminalDropPaste.receiveCommand(batch: batch, name: file.remoteName, size: file.size)
        // Looked up on PATH, as herdr does, and with no shell in between:
        // the arguments go to ssh as they are.
        let command = LocalCommand.Command(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["ssh"] + TerminalDropPaste.sshArguments(to: machine.target, running: receive),
            standardInput: file.descriptor
        )
        // ssh reads the descriptor's own open file, so how far into it the
        // offset has moved is how much has been sent.
        let descriptor = file.descriptor
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw TerminalDropError.unreadable(errno) }
        let watcher = Task {
            while !Task.isCancelled {
                let offset = lseek(descriptor, 0, SEEK_CUR)
                if offset > 0 { progress(Int64(offset)) }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        // The deadline is only a backstop: `TerminalDropController` gives up
        // on an upload that stops moving long before it, and cancelling ends
        // ssh, whereupon the far end removes what it got.
        let output = try await LocalCommand.run(command, timeout: 30 * 60, maxOutputBytes: 64 * 1024) { status, stderr in
            TerminalDropError.failed(status: status, detail: TerminalDropPaste.lastLine(of: stderr))
        }
        progress(file.size)
        guard let path = TerminalDropPaste.receivedPath(in: String(decoding: output, as: UTF8.self),
                                                        batch: batch, name: file.remoteName) else {
            throw TerminalDropError.unconfirmed
        }
        return path
    }

    func close() async {}
}
#endif
