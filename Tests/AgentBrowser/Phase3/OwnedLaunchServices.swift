import AppKit
import CryptoKit
import Darwin

// Test-only normal macOS bundle opening. The app is not a Popen child;
// public EVFILT_PROC/NOTE_EXITSTATUS supplies its actual kernel exit status.
struct LaunchInput: Decodable {
    let bundle: String
    let executable: String
    let executableSHA256: String
    let environment: [String: String]
    let arguments: [String]
}
let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard arguments.count == 2 else { fail("One owned private launch request required") }
let request = try OwnedOperatorPaths.existing(arguments[1])
try OwnedOperatorPaths.owned(request, type: .typeRegular, mode: 0o600)
let input = try JSONDecoder().decode(LaunchInput.self, from: Data(contentsOf: URL(fileURLWithPath: request)))
let root = try OwnedOperatorPaths.existing(input.environment["SHEPHERD_OWNED_OPERATOR_ROOT"] ?? "")
try OwnedOperatorPaths.owned(root, type: .typeDirectory, mode: 0o700)
guard OwnedOperatorPaths.isInside(request, root: root), root.hasPrefix("/private/tmp/shepherd-operator-owned-") else { fail("Owned root/request binding required") }
let marker = try OwnedOperatorPaths.descendant(root + "/owned-operator.json", root: root)
try OwnedOperatorPaths.owned(marker, type: .typeRegular, mode: 0o600)
let markerInput = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: marker))) as? [String: String]
guard markerInput?["marker"] == "owned-operator-v1", let machine = markerInput?["machineID"], UUID(uuidString: machine) != nil,
      markerInput?["defaultsDomain"] == "com.bldg-7.shepherd.operator-fixture." + machine else { fail("Private marker/domain mismatch") }
let home = try OwnedOperatorPaths.descendant(root + "/home", root: root)
let profile = try OwnedOperatorPaths.descendant(root + "/browser", root: root)
let socket = try OwnedOperatorPaths.descendant(home + "/.config/herdr/herdr.sock", root: root)
try OwnedOperatorPaths.owned(socket, type: .typeSocket)
guard input.arguments.isEmpty,
      Set(input.environment.keys) == Set(["HOME", "PATH", "SHELL", "TERM", "LANG", "HERDR_CONFIG_PATH", "SHEPHERD_BROWSER_TEST_ROOT", "SHEPHERD_OWNED_OPERATOR_ROOT"]),
      try OwnedOperatorPaths.existing(input.environment["HOME"] ?? "") == home,
      try OwnedOperatorPaths.existing(input.environment["SHEPHERD_BROWSER_TEST_ROOT"] ?? "") == profile,
      try OwnedOperatorPaths.existing(input.environment["HERDR_CONFIG_PATH"] ?? "") == home + "/.config/herdr/config.toml",
      input.environment["PATH"] == "/usr/bin:/bin", input.environment["SHELL"] == "/bin/sh",
      input.environment["TERM"] == "xterm-256color", input.environment["LANG"] == "en_US.UTF-8" else { fail("Exact private launch environment required") }
let bundlePath = try OwnedOperatorPaths.existing(input.bundle)
let executable = try OwnedOperatorPaths.existing(input.executable)
let bundleURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
guard bundlePath.hasSuffix("/Shepherd.app"), executable == bundlePath + "/Contents/MacOS/Shepherd",
      Bundle(url: bundleURL)?.bundleIdentifier == "com.bldg-7.shepherd.operator-fixture",
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.bldg-7.shepherd.operator-fixture").isEmpty else { fail("Unique nonrunning owned bundle required") }
@MainActor func executableHash(_ path: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
}
guard try executableHash(executable) == input.executableSHA256 else { fail("Executable hash mismatch") }
@MainActor func write(_ name: String, _ value: [String: Any]) throws {
    let path = try OwnedOperatorPaths.descendant(root + "/" + name, root: root, allowMissingLeaf: true)
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.environment = input.environment
configuration.arguments = input.arguments
configuration.createsNewApplicationInstance = true
configuration.activates = true
configuration.allowsRunningApplicationSubstitution = false
configuration.promptsUserIfNeeded = false
configuration.addsToRecentItems = false
configuration.hidesOthers = false
try write("launchservices-input.json", ["bundle": bundlePath, "executable": executable, "executableSHA256": input.executableSHA256,
    "environment": input.environment, "arguments": input.arguments, "createsNewApplicationInstance": true, "activates": true,
    "allowsRunningApplicationSubstitution": false, "promptsUserIfNeeded": false, "addsToRecentItems": false])
let requestedAt = Date().timeIntervalSince1970
var callbackFinished = false
var monitored: NSRunningApplication?
var queue: Int32 = -1
var originalStart: String?
var launchFailed = false
NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { app, error in
    DispatchQueue.main.async {
        do {
            var receipt: [String: Any] = ["requestedAtEpochSeconds": requestedAt, "callbackAtEpochSeconds": Date().timeIntervalSince1970,
                "returnedPID": app?.processIdentifier ?? 0, "errorPresent": error != nil,
                "errorDomain": (error as NSError?)?.domain ?? "", "errorCode": (error as NSError?)?.code ?? 0]
            try write("launchservices-callback.json", receipt)
            if let error = error as NSError? { receipt["errorDomain"] = error.domain; receipt["errorCode"] = error.code; receipt["errorDescription"] = error.localizedDescription }
            guard error == nil, let app else {
                try write("launchservices-result.json", receipt); launchFailed = true; callbackFinished = true; return
            }
            var info = proc_bsdinfo()
            guard app.bundleIdentifier == "com.bldg-7.shepherd.operator-fixture",
                  let path = app.executableURL?.path, try OwnedOperatorPaths.existing(path) == executable,
                  try executableHash(executable) == input.executableSHA256,
                  proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid() else { throw POSIXError(.EPERM) }
            var kernelPath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathSize = kernelPath.withUnsafeMutableBytes { proc_pidpath(app.processIdentifier, $0.baseAddress, UInt32($0.count)) }
            guard pathSize > 0, try OwnedOperatorPaths.existing(String(cString: kernelPath)) == executable else { throw POSIXError(.EPERM) }
            originalStart = "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
            queue = kqueue()
            guard queue >= 0 else { throw POSIXError(.EIO) }
            var change = kevent(ident: UInt(app.processIdentifier), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var registered = proc_bsdinfo()
            guard !app.isTerminated,
                  proc_pidinfo(app.processIdentifier, PROC_PIDTBSDINFO, 0, &registered, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  registered.pbi_start_tvsec == info.pbi_start_tvsec && registered.pbi_start_tvusec == info.pbi_start_tvusec else { throw POSIXError(.ESRCH) }
            monitored = app
            receipt["identityVerified"] = true; receipt["kernelStart"] = originalStart!
            receipt["activeAtCallback"] = app.isActive; receipt["terminatedAtCallback"] = app.isTerminated
            receipt["exitObserverRegistered"] = true
            try write("launchservices-result.json", receipt)
            callbackFinished = true
        } catch {
            try? write("launchservices-result.json", ["errorPresent": true, "verificationError": String(describing: error),
                "returnedPID": app?.processIdentifier ?? 0, "callbackAtEpochSeconds": Date().timeIntervalSince1970])
            launchFailed = true; callbackFinished = true
        }
    }
}
let callbackDeadline = Date(timeIntervalSinceNow: 15)
while !callbackFinished && callbackDeadline.timeIntervalSinceNow > 0 {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
guard callbackFinished, !launchFailed, let app = monitored else { fail("LaunchServices callback failed or timed out; no retry") }
defer { if queue >= 0 { close(queue) } }
let lifecycleDeadline = Date(timeIntervalSinceNow: 70)
while lifecycleDeadline.timeIntervalSinceNow > 0 {
    var event = kevent(); var timeout = timespec(tv_sec: 0, tv_nsec: 0)
    let count = kevent(queue, nil, 0, &event, 1, &timeout)
    guard count >= 0 else { fail("Owned exit observer failed") }
    if count == 1 {
        try write("launchservices-exit-event.json", ["pid": app.processIdentifier, "ident": event.ident, "flags": event.flags, "fflags": event.fflags, "data": event.data])
        guard event.ident == UInt(app.processIdentifier), event.flags & UInt16(EV_ERROR) == 0,
              event.fflags & UInt32(NOTE_EXIT) != 0, event.fflags & UInt32(NOTE_EXITSTATUS) != 0 else { fail("Actual owned kernel exit status unavailable") }
        let status = Int(event.data)
        let signal = status & 0x7f
        try write("launchservices-exit.json", ["pid": app.processIdentifier, "kernelStart": originalStart!, "rawKernelWaitStatus": status,
            "exitCode": signal == 0 ? (status >> 8) & 0xff : -1, "signal": signal,
            "observedAtEpochSeconds": Date().timeIntervalSince1970, "source": "public EVFILT_PROC NOTE_EXITSTATUS"])
        exit(signal == 0 && ((status >> 8) & 0xff) == 0 ? 0 : 1)
    }
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
fail("Owned lifecycle exit observation deadline exceeded; no cleanup/success claim")
