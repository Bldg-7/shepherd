import Foundation
import Darwin

// Production paste/plan/receive-script code, the actual receive script run by
// /bin/sh under owned test HOMEs, the actual this-Mac-machine uploader and
// LocalCommand against a fake `ssh` on PATH. No network, no user files.
@main @MainActor enum FileDropTests {
    static var checks = 0
    static func check(_ condition: Bool, _ why: String) { precondition(condition, why); checks += 1 }

    static var work = ""
    static var bin = ""

    static func main() async throws {
        work = CommandLine.arguments[1]
        bin = CommandLine.arguments[2]
        pasting()
        planning()
        receipts()
        commands()
        try opening()
        try receiveScript()
        try cleanupAndLinks()
        try earlierFolder()
        try throughHostSSH()
        try everyShell()
        try await localCommandInput()
        try await thisMacMachine()
        print("file drop checks: \(checks)")
    }

    // MARK: - Pure

    static func pasting() {
        check(TerminalDropPaste.escaped("/Users/me/My Shots/a(1).png") == #"/Users/me/My\ Shots/a\(1\).png"#, "spaces and parentheses are escaped")
        check(TerminalDropPaste.escaped(##"/tmp/it's "$HOME"&;|*?!#`[x]{y}<z>\.gif"##)
              == ##"/tmp/it\'s\ \"\$HOME\"\&\;\|\*\?\!\#\`\[x\]\{y\}\<z\>\\.gif"##, "every shell metacharacter is escaped")
        check(TerminalDropPaste.escaped("/Users/me/스크린샷 1.png") == #"/Users/me/스크린샷\ 1.png"#, "non-ASCII is kept as it is")
        for bad in ["/tmp/a\u{1b}[201~b.png", "/tmp/a\nb.png", "/tmp/a\rb", "/tmp/a\u{7f}", "/tmp/a\u{9b}b", "/tmp/a\tb", ""] {
            check(TerminalDropPaste.escaped(bad) == nil, "a path with a control character is refused: \(bad.debugDescription)")
        }
        check(TerminalDropPaste.pasteText(escaped: ["/a", #"/b\ c"#]) == #"/a /b\ c "#, "paths joined with spaces, one after the last")
    }

    static func planning() {
        let urls = ["/d/A.PNG", "/d/b.JpEg", "/d/c.gif", "/d/d.webp", "/d/e.jpg", "/d/f.bmp", "/d/g.heic", "/d/h.tiff", "/d/notes.pdf", "/d/folder/"]
            .map { URL(fileURLWithPath: $0, isDirectory: $0.hasSuffix("/")) }
        let plan = TerminalDropPaste.plan(urls)
        check(plan.uploads.map(\.name) == ["A.PNG", "b.JpEg", "c.gif", "d.webp", "e.jpg"], "png/jpg/jpeg/gif/webp in any case are images")
        check(plan.uploads.map(\.remoteName) == ["A.png", "b.jpeg", "c.gif", "d.webp", "e.jpg"], "the extension there is lowercase")
        check(plan.notImages == ["f.bmp", "g.heic", "h.tiff", "notes.pdf", "folder"], "everything else, folders too, is not uploaded")
        check(plan.overLimit.isEmpty, "under the limit")
        check(!TerminalDropPaste.isImage(URL(fileURLWithPath: "/d/x.png", isDirectory: true)), "a folder named like an image is not one")
        check(TerminalDropPaste.plan([URL(string: "https://example.invalid/a.png")!]).notImages == ["a.png"], "only file URLs are uploaded")

        let many = (1...23).map { URL(fileURLWithPath: "/d/s\($0).png") }
        let limited = TerminalDropPaste.plan(many)
        check(limited.uploads.count == 20 && limited.overLimit == ["s21.png", "s22.png", "s23.png"], "20 images per drop, the rest listed")

        let same = ["/a/shot.png", "/b/shot.png", "/c/SHOT.PNG", "/d/스크린샷.png", "/e/스크린샷.png", "/f/.hidden.gif", "/g/-x.png", "/h/a b$(touch x)'.png"]
            .map { URL(fileURLWithPath: $0) }
        let names = TerminalDropPaste.plan(same).uploads.map(\.remoteName)
        check(names == ["shot.png", "shot-2.png", "SHOT-3.png", "____.png", "____-2.png", "_.hidden.gif", "_-x.png", "a_b__touch_x__.png"],
              "names are made safe and unique without regard to case: \(names)")
        let long = TerminalDropPaste.remoteName(for: String(repeating: "a", count: 300) + ".png", avoiding: [])
        check(long == String(repeating: "a", count: 80) + ".png", "a long name is cut to 80 before its extension")
        check(TerminalDropPaste.remoteName(for: "한.png", avoiding: []) == "_.png", "one underscore per character, however it is stored")
        for name in names + [long] {
            check(name.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, "\(name) passes the receive script's own check")
        }
    }

    static func receipts() {
        let batch = "0f0e0d0c-0b0a-4908-8706-050403020100"
        let good = "/home/me/.cache/3rdr/drops/\(batch)/shot.png"
        check(TerminalDropPaste.receivedPath(in: "Welcome!\nSHEPHERD_DROP_OK /fake/x\nmotd\nSHEPHERD_DROP_OK \(good)\n", batch: batch, name: "shot.png") == good,
              "the last receipt line counts, whatever the startup files print")
        check(TerminalDropPaste.receivedPath(in: "SHEPHERD_DROP_OK \(good)\r\n", batch: batch, name: "shot.png") == good, "CRLF")
        check(TerminalDropPaste.receivedPath(in: "SHEPHERD_DROP_OK \(good)", batch: batch, name: "other.png") == nil, "another file's path is refused")
        check(TerminalDropPaste.receivedPath(in: "SHEPHERD_DROP_OK \(good)", batch: "ffffffff-0b0a-4908-8706-050403020100", name: "shot.png") == nil, "another batch's path is refused")
        check(TerminalDropPaste.receivedPath(in: "SHEPHERD_DROP_OK home/.cache/3rdr/drops/\(batch)/shot.png", batch: batch, name: "shot.png") == nil, "a relative path is refused")
        check(TerminalDropPaste.receivedPath(in: "SHEPHERD_DROP_OK /h\u{1b}[201~/.cache/3rdr/drops/\(batch)/shot.png", batch: batch, name: "shot.png") == nil, "a path with a control character is refused")
        check(TerminalDropPaste.receivedPath(in: "nothing here", batch: batch, name: "shot.png") == nil, "no receipt, no path")
        check(TerminalDropPaste.lastLine(of: "debug1: x\nssh: connect to host gpu port 22: Connection refused\r\n\n") == "ssh: connect to host gpu port 22: Connection refused", "ssh's last line")
        check(TerminalDropPaste.lastLine(of: "\u{1b}[31mred\u{1b}[0m") == "", "a line with control characters isn't shown")
    }

    static func commands() {
        for target in ["gpu", "me@gpu", "ssh://me@gpu:2222", "gpu box'$(touch x)"] {
            check(TerminalDropPaste.isUsableTarget(target), "\(target) is usable")
        }
        for target in ["", "-oProxyCommand=touch x", "gpu\nx", String(repeating: "g", count: 1025)] {
            check(!TerminalDropPaste.isUsableTarget(target), "\(target.debugDescription) is refused")
        }
        let arguments = TerminalDropPaste.sshArguments(to: "gpu", running: "RECEIVE")
        check(arguments.first == "-T" && arguments.suffix(3) == ["--", "gpu", "RECEIVE"], "no terminal, and the target after --")
        check(Array(arguments.dropFirst().dropLast(3)) == HerdrExecutable.sshOptions, "herdr's own non-interactive ssh options")
        check(HerdrExecutable.sshOptions.contains("StrictHostKeyChecking=yes") && HerdrExecutable.sshOptions.contains("BatchMode=yes"),
              "no new host key is trusted and nothing is asked")
        check(!TerminalDropPaste.receiveScript.contains("\n") && !TerminalDropPaste.receiveScript.contains("\\\\")
              && !TerminalDropPaste.receiveScript.contains("!"), "one line, with no backslash pairs and no !")
    }

    static func opening() throws {
        let dir = "\(work)/open"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/ok.png"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path))
        let file = try TerminalDropFile.open(URL(fileURLWithPath: path), remoteName: "ok.png")
        check(file.size == 3 && file.name == "ok.png" && fcntl(file.descriptor, F_GETFD) & FD_CLOEXEC != 0, "a regular file opens, close-on-exec")
        check(fcntl(file.descriptor, F_GETFL) & O_NONBLOCK == 0, "blocking once open")
        func refused(_ path: String, _ expected: TerminalDropError) {
            do { _ = try TerminalDropFile.open(URL(fileURLWithPath: path), remoteName: "x.png"); check(false, "\(path) must be refused") }
            catch let error as TerminalDropError { check(error == expected, "\(path): \(error)") }
            catch { check(false, "\(error)") }
        }
        refused(dir, .notRegularFile)
        precondition(mkfifo("\(dir)/fifo.png", 0o600) == 0)
        refused("\(dir)/fifo.png", .notRegularFile)
        refused("\(dir)/missing.png", .unreadable(ENOENT))
        for (name, size) in [("limit.png", TerminalDropPaste.maximumFileBytes), ("over.png", TerminalDropPaste.maximumFileBytes + 1)] {
            let fd = Darwin.open("\(dir)/\(name)", O_CREAT | O_WRONLY, 0o600)
            precondition(fd >= 0 && ftruncate(fd, off_t(size)) == 0); Darwin.close(fd)
        }
        check((try? TerminalDropFile.open(URL(fileURLWithPath: "\(dir)/limit.png"), remoteName: "l.png"))?.size == TerminalDropPaste.maximumFileBytes, "16 MiB exactly is taken")
        refused("\(dir)/over.png", .tooLarge)
    }

    // MARK: - The receive script, under /bin/sh

    struct Run { let status: Int32; let stdout: String; let stderr: String }

    /// `commandLine` the way a login shell is given it by sshd.
    static func shell(_ commandLine: String, home: String, input: Data = Data(), path: String = "/usr/bin:/bin", loginShell: String = "/bin/sh") throws -> Run {
        let inputPath = "\(work)/stdin-\(UUID().uuidString)"
        try input.write(to: URL(fileURLWithPath: inputPath))
        defer { try? FileManager.default.removeItem(atPath: inputPath) }
        let cwd = "\(work)/cwd"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-c", commandLine]
        process.environment = ["HOME": home, "PATH": path]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = FileHandle(forReadingAtPath: inputPath)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
    }

    static func mode(_ path: String) -> mode_t {
        var info = stat(); precondition(lstat(path, &info) == 0, path); return info.st_mode & 0o7777
    }
    static func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
    static func injected() -> [String] {
        (FileManager.default.enumerator(atPath: work)?.allObjects as? [String] ?? []).filter { $0.contains("INJECTED") }
    }

    static func receiveScript() throws {
        let home = "\(work)/script-home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let batch = UUID().uuidString.lowercased()
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        let run = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "shot.png", size: Int64(bytes.count)), home: home, input: bytes)
        let drops = "\(home)/.cache/3rdr/drops"
        let expected = "\(drops)/\(batch)/shot.png"
        check(run.status == 0 && TerminalDropPaste.receivedPath(in: run.stdout, batch: batch, name: "shot.png") == expected, "received: \(run)")
        check(FileManager.default.contents(atPath: expected) == bytes, "every byte, unchanged")
        check(mode("\(home)/.cache") == 0o700 && mode("\(home)/.cache/3rdr") == 0o700 && mode(drops) == 0o700 && mode("\(drops)/\(batch)") == 0o700,
              "folders only the account's")
        check(mode(expected) == 0o600 && !exists(expected + ".part"), "file only the account's, nothing partial left")

        let second = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "two.png", size: 3), home: home, input: Data([9, 9, 9]))
        check(second.status == 0 && exists("\(drops)/\(batch)/two.png"), "a second file in the same batch")

        let again = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "shot.png", size: 3), home: home, input: Data([1, 2, 3]))
        check(again.status == 72 && FileManager.default.contents(atPath: expected) == bytes && !exists(expected + ".part"), "an existing file is left alone: \(again.status)")

        let shortBatch = UUID().uuidString.lowercased()
        let short = try shell(TerminalDropPaste.receiveCommand(batch: shortBatch, name: "cut.png", size: 10), home: home, input: Data([1, 2, 3]))
        check(short.status == 74 && !exists("\(drops)/\(shortBatch)"), "short of the stated size: the .part and its empty batch are removed")
        let longBatch = UUID().uuidString.lowercased()
        let long = try shell(TerminalDropPaste.receiveCommand(batch: longBatch, name: "big.png", size: 2), home: home, input: Data([1, 2, 3]))
        check(long.status == 74 && !exists("\(drops)/\(longBatch)"), "more than the stated size too")
        let partial = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "cut.png", size: 10), home: home, input: Data([1]))
        check(partial.status == 74 && !exists("\(drops)/\(batch)/cut.png.part") && exists(expected), "a failure in a batch keeps the batch's other files")

        let malformed: [(String, String, String)] = [
            (batch.uppercased(), "a.png", "3"), ("-rf", "a.png", "3"), ("../x", "a.png", "3"), ("", "a.png", "3"),
            (batch, ".hidden.png", "3"), (batch, "-x.png", "3"), (batch, "a/b.png", "3"), (batch, "a$(touch INJECTED-name).png", "3"),
            (batch, "a'INJECTED.png", "3"), (batch, "a b.png", "3"), (batch, "", "3"), (batch, "a.png", "3a"), (batch, "a.png", "-1"), (batch, "a.png", ""),
            (batch + "\n", "a.png", "3"), (batch, "a.png\n", "3"), (batch, "a.png", "3\n"), (batch, "é.png", "3"), (batch, "a.png", "٣"),
            ("\n", "a.png", "3"), (batch, "\n", "3"), (batch, "a.png", "\n"), (batch, "a.png", "+3"),
        ]
        for (b, n, s) in malformed {
            let line = "sh -c " + [TerminalDropPaste.receiveScript, "3rdr-drop", b, n, s].map(shellQuoted).joined(separator: " ")
            let result = try shell(line, home: home, input: Data([1, 2, 3]))
            check(result.status == 64, "\(b) \(n) \(s) refused: \(result.status)")
        }
        check(injected().isEmpty, "no argument ran as code")
        let bare = try shell("sh -c " + shellQuoted(TerminalDropPaste.receiveScript), home: home)
        check(bare.status != 0 && bare.stdout.isEmpty, "no arguments, nothing received")
    }

    static func cleanupAndLinks() throws {
        let home = "\(work)/cleanup-home"
        let drops = "\(home)/.cache/3rdr/drops"
        let fm = FileManager.default
        for dir in ["\(drops)/old-batch", "\(drops)/new-batch", "\(home)/.cache/other-old"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try Data([1]).write(to: URL(fileURLWithPath: "\(drops)/old-batch/x.png"))
        try Data([1]).write(to: URL(fileURLWithPath: "\(drops)/old-file"))
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86_400)
        for path in ["\(drops)/old-batch", "\(drops)/old-file", "\(home)/.cache/other-old"] {
            try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: path)
        }
        let batch = UUID().uuidString.lowercased()
        let run = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "a.png", size: 1), home: home, input: Data([7]))
        check(run.status == 0, "upload alongside old batches")
        check(!exists("\(drops)/old-batch") && exists("\(drops)/new-batch") && exists("\(drops)/\(batch)/a.png"), "only batches over a day old go")
        check(exists("\(drops)/old-file") && exists("\(home)/.cache/other-old"), "nothing but old folders in drops is touched")

        // The drops folder, or the one it is in, a symbolic link: refused,
        // and nothing written where it points.
        for (index, link) in ["\(work)/link-home-1/.cache/3rdr/drops", "\(work)/link-home-2/.cache/3rdr"].enumerated() {
            let home = "\(work)/link-home-\(index + 1)"
            let elsewhere = "\(work)/elsewhere-\(index + 1)"
            try fm.createDirectory(atPath: elsewhere + "/drops", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: index == 0 ? elsewhere + "/drops" : elsewhere)
            let result = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "a.png", size: 1), home: home, input: Data([7]))
            check(result.status == 70, "a symbolic link in the way is refused: \(result.status)")
            check((try fm.contentsOfDirectory(atPath: elsewhere + "/drops")).isEmpty, "nothing written through the link")
        }
    }

    /// ~/.cache/shepherd/drops, where earlier versions put uploads: its day-old
    /// batches go as in the new folder, then the folder once empty, and
    /// nothing else — not ~/.cache/shepherd, not what a link points to.
    static func earlierFolder() throws {
        let fm = FileManager.default
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 86_400)
        func receive(_ home: String) throws -> Run {
            try shell(TerminalDropPaste.receiveCommand(batch: UUID().uuidString.lowercased(), name: "a.png", size: 1), home: home, input: Data([7]))
        }

        let home = "\(work)/earlier-home"
        let earlier = "\(home)/.cache/shepherd/drops"
        for dir in ["\(earlier)/old-batch", "\(earlier)/recent-batch", "\(home)/.cache/shepherd/other"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try Data([1]).write(to: URL(fileURLWithPath: "\(earlier)/old-batch/x.png"))
        try Data([1]).write(to: URL(fileURLWithPath: "\(earlier)/recent-batch/y.png"))
        for path in ["\(earlier)/old-batch", "\(home)/.cache/shepherd/other"] {
            try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: path)
        }
        let first = try receive(home)
        check(first.status == 0 && first.stdout.contains("/.cache/3rdr/drops/"), "received into the new folder: \(first)")
        check(!exists("\(earlier)/old-batch") && exists("\(earlier)/recent-batch/y.png"), "only the earlier folder's day-old batches go")
        check(exists("\(home)/.cache/shepherd/other"), "nothing beside the earlier drops folder is touched")
        try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: "\(earlier)/recent-batch")
        let second = try receive(home)
        check(second.status == 0 && !exists(earlier), "the earlier drops folder goes once empty: \(second.status)")
        check(exists("\(home)/.cache/shepherd/other"), "and the folder it was in stays")
        let third = try receive(home)
        check(third.status == 0 && !exists(earlier), "no earlier folder, nothing to do")

        // The earlier drops folder, or the one it is in, a symbolic link: left
        // as it is, and nothing removed where it points.
        for (index, link) in ["\(work)/earlier-link-1/.cache/shepherd/drops", "\(work)/earlier-link-2/.cache/shepherd"].enumerated() {
            let home = "\(work)/earlier-link-\(index + 1)"
            let elsewhere = "\(work)/earlier-elsewhere-\(index + 1)"
            try fm.createDirectory(atPath: elsewhere + "/drops/old-batch", withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: elsewhere + "/drops/old-batch")
            try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: index == 0 ? elsewhere + "/drops" : elsewhere)
            let result = try receive(home)
            check(result.status == 0, "a link in the earlier folder's place doesn't stop an upload: \(result.status)")
            check(exists(link) && exists(elsewhere + "/drops/old-batch"), "nothing removed through the link")
        }
    }

    /// A pane on one of the host's herdr machines: the host's login shell
    /// runs `hostCommand`, the host's (fake) ssh carries the receive on.
    static func throughHostSSH() throws {
        let hostHome = "\(work)/host-home", machineHome = "\(work)/machine-home"
        try FileManager.default.createDirectory(atPath: hostHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: machineHome, withIntermediateDirectories: true)
        let target = "gpu box'$(touch INJECTED-target)`touch INJECTED-tick`"
        let batch = UUID().uuidString.lowercased()
        let line = TerminalDropPaste.hostCommand(target: target, receive: TerminalDropPaste.receiveCommand(batch: batch, name: "d.png", size: 4))
        let run = try shell(line, home: hostHome, input: Data([4, 3, 2, 1]), path: "\(bin):/usr/bin:/bin")
        let expected = "\(machineHome)/.cache/3rdr/drops/\(batch)/d.png"
        check(run.status == 0 && TerminalDropPaste.receivedPath(in: run.stdout, batch: batch, name: "d.png") == expected, "through the host: \(run)")
        check(FileManager.default.contents(atPath: expected) == Data([4, 3, 2, 1]), "the bytes reach the machine")
        check(!exists("\(hostHome)/.cache"), "nothing is left on the host")
        let targets = (try String(contentsOfFile: "\(bin)/ssh-targets.log", encoding: .utf8)).split(separator: "\n").map(String.init)
        check(targets.last == target, "the target reaches ssh as one argument, as it is")
        check(injected().isEmpty, "the target didn't run as code on the host")
    }

    /// The command lines get through whatever login shell the account
    /// has, on to whatever `sh` is: bash as sh here, dash as on Debian.
    static func everyShell() throws {
        let dashBin = "\(work)/dash-bin"
        try FileManager.default.createDirectory(atPath: dashBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(dashBin)/sh", withDestinationPath: "/bin/dash")
        let machineHome = "\(work)/machine-home"
        for login in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/ksh", "/bin/dash", "/bin/tcsh", "/bin/csh"] where FileManager.default.isExecutableFile(atPath: login) {
            for inner in ["/usr/bin:/bin", "\(dashBin):/usr/bin:/bin"] {
                let home = "\(work)/shell-home"
                let batch = UUID().uuidString.lowercased()
                let bytes = Data((0..<5000).map { UInt8($0 % 256) })
                let run = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "s.png", size: Int64(bytes.count)), home: home, input: bytes, path: inner, loginShell: login)
                let path = TerminalDropPaste.receivedPath(in: run.stdout, batch: batch, name: "s.png")
                check(run.status == 0 && path.flatMap { FileManager.default.contents(atPath: $0) } == bytes, "\(login) then sh in \(inner): \(run)")
                let short = try shell(TerminalDropPaste.receiveCommand(batch: batch, name: "t.png", size: 9), home: home, input: Data([1]), path: inner, loginShell: login)
                check(short.status == 74 && !exists("\(home)/.cache/3rdr/drops/\(batch)/t.png.part"), "\(login): a short file is removed")
                // Through the host's ssh: the host's login shell, then the
                // machine's (the fake ssh's /bin/sh), then `sh`.
                let hostBatch = UUID().uuidString.lowercased()
                let line = TerminalDropPaste.hostCommand(target: "gpu'$(touch INJECTED-shell)", receive: TerminalDropPaste.receiveCommand(batch: hostBatch, name: "h.png", size: 3))
                let hosted = try shell(line, home: "\(work)/host-home", input: Data([1, 2, 3]), path: "\(bin):" + inner, loginShell: login)
                check(hosted.status == 0 && TerminalDropPaste.receivedPath(in: hosted.stdout, batch: hostBatch, name: "h.png") == "\(machineHome)/.cache/3rdr/drops/\(hostBatch)/h.png",
                      "\(login) on the host: \(hosted)")
            }
        }
        check(injected().isEmpty, "no shell ran an argument as code")
        // A day-old batch goes under dash's find as well as bash's.
        let home = "\(work)/shell-home"
        let old = "\(home)/.cache/3rdr/drops/old"
        try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -90_000)], ofItemAtPath: old)
        let run = try shell(TerminalDropPaste.receiveCommand(batch: UUID().uuidString.lowercased(), name: "a.png", size: 1), home: home, input: Data([1]), path: "\(dashBin):/usr/bin:/bin", loginShell: "/bin/dash")
        check(run.status == 0 && !exists(old), "a 25-hour-old batch is removed")
    }

    // MARK: - This Mac's ssh

    static func localCommandInput() async throws {
        let path = "\(work)/stdin.bin"
        let bytes = Data((0..<100_000).map { UInt8($0 % 256) })
        try bytes.write(to: URL(fileURLWithPath: path))
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC); precondition(fd >= 0)
        defer { Darwin.close(fd) }
        let read = try await LocalCommand.run(.init(executable: URL(fileURLWithPath: "/bin/cat"), standardInput: fd)) { status, _ in POSIXError(.EIO) }
        check(read == bytes, "the command reads the descriptor as its stdin")
        check(lseek(fd, 0, SEEK_CUR) == off_t(bytes.count), "sharing the descriptor's offset")
        let none = try await LocalCommand.run(.init(executable: URL(fileURLWithPath: "/bin/cat"))) { status, _ in POSIXError(.EIO) }
        check(none.isEmpty, "without one, stdin is still /dev/null")
    }

    static func thisMacMachine() async throws {
        let machineHome = "\(work)/machine-home"
        let source = "\(work)/c-source.png"
        let bytes = Data((0..<300_000).map { UInt8(($0 * 7) % 256) })
        try bytes.write(to: URL(fileURLWithPath: source))
        let machine = HerdrMachine(id: "m1", label: "GPU", target: "gpu box'$(touch INJECTED-c)", session: "default", enabled: true)
        let uploader = LocalSSHDropUploader(machine: machine)
        let batch = UUID().uuidString.lowercased()
        let file = try TerminalDropFile.open(URL(fileURLWithPath: source), remoteName: "c.png")
        let progress = Meter()
        let path = try await uploader.upload(file, batch: batch, progress: { progress.record($0) })
        check(path == "\(machineHome)/.cache/3rdr/drops/\(batch)/c.png", "this Mac's ssh received it: \(path)")
        check(FileManager.default.contents(atPath: path) == bytes, "every byte")
        check(progress.last == Int64(bytes.count), "progress reaches the size")
        check(injected().isEmpty, "the target didn't run as code")
        let arguments = try String(contentsOfFile: "\(bin)/ssh-arguments.log", encoding: .utf8)
        check(arguments.contains("-T\n-o\nBatchMode=yes\n") && arguments.contains("--\n\(machine.target)\nsh -c "), "-T, herdr's options, then -- and the target")

        // ssh can't reach the machine: its own message, exit 255.
        FileManager.default.createFile(atPath: "\(bin)/unreachable", contents: nil)
        defer { try? FileManager.default.removeItem(atPath: "\(bin)/unreachable") }
        do {
            _ = try await uploader.upload(try TerminalDropFile.open(URL(fileURLWithPath: source), remoteName: "c2.png"), batch: batch, progress: { _ in })
            check(false, "unreachable must fail")
        } catch let error as TerminalDropError {
            check(error == .failed(status: 255, detail: "ssh: connect to host \(machine.target) port 22: Connection refused"), "\(error)")
            check(error.errorDescription == "ssh: connect to host \(machine.target) port 22: Connection refused" && !error.concernsOnlyThisFile, "ssh's message, and the drop's other files aren't tried")
        }
        try FileManager.default.removeItem(atPath: "\(bin)/unreachable")

        // A target that would be an option never reaches ssh.
        let before = try String(contentsOfFile: "\(bin)/ssh-targets.log", encoding: .utf8)
        do {
            _ = try await LocalSSHDropUploader(machine: HerdrMachine(id: "m2", label: "x", target: "-oProxyCommand=touch INJECTED-o", session: "default", enabled: true))
                .upload(try TerminalDropFile.open(URL(fileURLWithPath: source), remoteName: "c3.png"), batch: batch, progress: { _ in })
            check(false, "an option-like target must be refused")
        } catch let error as TerminalDropError {
            check(error == .unusableTarget, "\(error)")
        }
        check(try String(contentsOfFile: "\(bin)/ssh-targets.log", encoding: .utf8) == before, "ssh not run")

        // Cancelled while ssh is still connecting: ssh is ended, promptly.
        FileManager.default.createFile(atPath: "\(bin)/hold", contents: nil)
        let targetsBefore = (try String(contentsOfFile: "\(bin)/ssh-targets.log", encoding: .utf8)).split(separator: "\n").count
        let held = Task {
            try await uploader.upload(try TerminalDropFile.open(URL(fileURLWithPath: source), remoteName: "c4.png"), batch: batch, progress: { _ in })
        }
        let started = ContinuousClock.now
        while (try String(contentsOfFile: "\(bin)/ssh-targets.log", encoding: .utf8)).split(separator: "\n").count == targetsBefore {
            try await Task.sleep(for: .milliseconds(20))
            precondition(ContinuousClock.now - started < .seconds(10), "fake ssh didn't start")
        }
        try FileManager.default.removeItem(atPath: "\(bin)/hold")
        let cancelledAt = ContinuousClock.now
        held.cancel()
        do { _ = try await held.value; check(false, "a cancelled upload must not succeed") }
        catch is CancellationError { check(ContinuousClock.now - cancelledAt < .seconds(5), "ssh ended within LocalCommand's stop budget") }
        check(!exists("\(machineHome)/.cache/3rdr/drops/\(batch)/c4.png"), "nothing arrived")
    }

    nonisolated final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func record(_ sent: Int64) { lock.withLock { value = max(value, sent) } }
        var last: Int64 { lock.withLock { value } }
    }
}
