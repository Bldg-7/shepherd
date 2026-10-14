import Foundation
import Darwin
import NIOCore

/// The actual listener on owned ephemeral loopback ports; never 9333/9334.
/// A child spawned while it is open (a terminal attach is forked and exec'd)
/// must not keep its port after `stop()`.
@main @MainActor struct CDPListenerTests {
    static func main() async throws {
        let first = CDPListener()
        let port = try await start(first, port: 0)
        precondition(port > 0, "port 0 must report the port actually bound")
        print("PASS: port 0 reports the bound port")

        let busy = CDPListener(), before = openDescriptors()
        do { _ = try await start(busy, port: port); fail("a second listener bound a port in use") }
        catch let error as IOError where error.errnoCode == EADDRINUSE {}
        precondition(openDescriptors() == before, "a failed start left a descriptor open")
        print("PASS: a port in use fails the start and leaves no descriptor open")

        let child = spawnSleep()
        await first.stop()
        precondition(kill(child, 0) == 0, "the spawned child must still be running")
        let second = CDPListener()
        let reopened: Result<Int, Error>
        do { reopened = .success(try await start(second, port: port)) } catch { reopened = .failure(error) }
        kill(child, SIGKILL)
        var status: CInt = 0
        _ = waitpid(child, &status, 0)
        switch reopened {
        case .success(let again) where again == port: break
        case .success(let again): fail("reopened on \(again), not \(port)")
        case .failure(let error): fail("port \(port) could not be reopened while a spawned child runs: \(error)")
        }
        await second.stop()
        print("PASS: a child spawned while the listener was open does not keep its port after stop")
    }

    static func start(_ listener: CDPListener, port: Int) async throws -> Int {
        try await listener.start(port: port, token: "owned-test-token",
                                 authorizeRoute: { _ in false }, accept: { _, socket, _ in socket.close() })
    }

    /// Like SwiftTerm's forkpty and execve: the child gets every descriptor
    /// not marked close-on-exec. Foundation's Process would close them.
    static func spawnSleep() -> pid_t {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let code = posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environment)
        precondition(code == 0, "posix_spawn failed: \(code)")
        return pid
    }

    static func openDescriptors() -> [CInt] {
        (0..<getdtablesize()).filter { fcntl($0, F_GETFD) != -1 }
    }

    static func fail(_ message: String) -> Never {
        print("FAIL: " + message)
        exit(1)
    }
}
