import AppKit
import ApplicationServices
import CryptoKit
import Darwin

// AX operations target only the explicitly identified owned PID/bundle.
// Never emits a desktop/global shortcut or requests accessibility permission.
let arguments = CommandLine.arguments
func processIdentity(_ process: pid_t) -> [String: String]? {
    guard let app = NSRunningApplication(processIdentifier: process), let url = app.executableURL,
          let path = try? OwnedOperatorPaths.existing(url.path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    var info = proc_bsdinfo()
    guard proc_pidinfo(process, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
          info.pbi_uid == getuid() else { return nil }
    return ["pid": String(process), "start": "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)", "executable": path,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
}
if arguments.count == 2 && arguments[1] == "foreground" {
    let prior = NSWorkspace.shared.frontmostApplication.flatMap { processIdentity($0.processIdentifier) } ?? [:]
    print(String(decoding: try JSONSerialization.data(withJSONObject: prior, options: [.sortedKeys]), as: UTF8.self))
    exit(0)
}
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
guard arguments.count >= 3, let pid = Int32(arguments[1]),
      let running = NSRunningApplication(processIdentifier: pid),
      running.bundleIdentifier == "com.bldg-7.shepherd.operator-fixture",
      AXIsProcessTrusted() else { fail("Owned PID/bundle and preexisting AX authorization required") }
let environment = ProcessInfo.processInfo.environment
func identity() -> [String: String] {
    guard let originalExecutable = running.executableURL,
          let executablePath = try? OwnedOperatorPaths.existing(originalExecutable.path),
          executablePath == environment["OWNED_OPERATOR_EXECUTABLE"],
          let data = try? Data(contentsOf: URL(fileURLWithPath: executablePath)) else { fail("Owned executable path required") }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard hash == environment["OWNED_OPERATOR_EXECUTABLE_SHA256"] else { fail("Owned executable hash changed") }
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
          info.pbi_uid == getuid() else { fail("Owned kernel identity unavailable") }
    let start = "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    if arguments[2] != "identity" { guard start == environment["OWNED_OPERATOR_START"] else { fail("Owned kernel identity changed") } }
    return ["start": start, "executable": executablePath, "sha256": hash]
}
_ = identity()
if arguments[2] == "dump" {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    _ = identity()
}
let application = AXUIElementCreateApplication(pid)
let capturedAt = Date().timeIntervalSince1970
let launchState: [String: Any] = ["pid": pid, "isFinishedLaunching": running.isFinishedLaunching,
    "isActive": running.isActive, "isTerminated": running.isTerminated, "capturedAtEpochSeconds": capturedAt]
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func read(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (error, value)
}
func arrayRead(_ element: AXUIElement, _ name: String) -> ([AXUIElement], [String: Any]) {
    let (error, value) = read(element, name)
    let elements = value as? [AXUIElement] ?? []
    return (elements, ["error": error.rawValue, "typeID": value.map { Int(CFGetTypeID($0)) } ?? 0,
                      "isElementArray": value is [AXUIElement], "count": elements.count])
}
let (windows, windowsRead) = arrayRead(application, kAXWindowsAttribute)
let (_, applicationChildrenRead) = arrayRead(application, kAXChildrenAttribute)
let (focusedError, focusedValue) = read(application, kAXFocusedWindowAttribute)
var windowEvidence: [[String: Any]] = []
for window in windows {
    var owner: pid_t = 0
    let pidError = AXUIElementGetPid(window, &owner)
    let (roleError, role) = read(window, kAXRoleAttribute)
    windowEvidence.append(["pid": owner, "pidError": pidError.rawValue,
                           "role": role as? String ?? "", "roleError": roleError.rawValue])
}
var nodes: [AXUIElement] = []
var depthTruncated = false, nodeTruncated = false, maximumDepth = 0
var childReads: [[String: Any]] = []
@MainActor func visit(_ element: AXUIElement, _ depth: Int = 0) {
    guard !nodes.contains(where: { CFEqual($0, element) }) else { return }
    maximumDepth = max(maximumDepth, depth)
    guard depth < 24 else { depthTruncated = true; return }
    guard nodes.count < 2500 else { nodeTruncated = true; return }
    nodes.append(element)
    let (descendants, diagnostic) = arrayRead(element, kAXChildrenAttribute)
    var row = diagnostic; row["nodeIndex"] = nodes.count - 1
    childReads.append(row)
    for child in descendants { visit(child, depth + 1) }
}
for window in windows { visit(window) }
visit(application)
let traversalErrors = childReads.filter {
    guard let error = $0["error"] as? Int32 else { return true }
    return error != AXError.success.rawValue && error != AXError.attributeUnsupported.rawValue && error != AXError.noValue.rawValue
}
let ownedWindowEstablished = windowsRead["error"] as? Int32 == AXError.success.rawValue &&
    windowsRead["isElementArray"] as? Bool == true && !windows.isEmpty &&
    windowEvidence.allSatisfy { $0["pid"] as? pid_t == pid && $0["pidError"] as? Int32 == 0 &&
        $0["roleError"] as? Int32 == 0 && $0["role"] as? String == kAXWindowRole } &&
    !depthTruncated && !nodeTruncated && traversalErrors.isEmpty
let operation = arguments[2]
switch operation {
case "identity":
    let data = try JSONSerialization.data(withJSONObject: identity(), options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "dump":
    var rows: [[String: Any]] = []
    for (index, element) in nodes.enumerated() {
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        rows.append(["index": index, "role": string(element, kAXRoleAttribute), "title": string(element, kAXTitleAttribute),
                     "description": string(element, kAXDescriptionAttribute), "value": attribute(element, kAXValueAttribute).map { String(describing: $0) } ?? "",
                     "identifier": string(element, kAXIdentifierAttribute), "actions": actions as? [String] ?? []])
    }
    var focusedOwner: pid_t = 0
    var focusedPIDError = AXError.invalidUIElement, focusedRoleError = AXError.invalidUIElement
    var focusedRole = ""
    if let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        focusedPIDError = AXUIElementGetPid(element, &focusedOwner)
        let (error, role) = read(element, kAXRoleAttribute)
        focusedRoleError = error; focusedRole = role as? String ?? ""
    }
    let focused: [String: Any] = ["error": focusedError.rawValue,
        "pid": focusedOwner, "pidError": focusedPIDError.rawValue, "role": focusedRole, "roleError": focusedRoleError.rawValue,
        "isOwnedWindow": focusedPIDError == .success && focusedOwner == pid && focusedRoleError == .success && focusedRole == kAXWindowRole, "present": focusedValue != nil,
        "typeID": focusedValue.map { Int(CFGetTypeID($0)) } ?? 0,
        "isReturnedWindow": focusedValue.map { value in windows.contains { CFEqual($0, value) } } ?? false]
    let result: [String: Any] = ["pid": pid, "capturedAtEpochSeconds": capturedAt,
        "nsRunningApplication": launchState, "windowsAttribute": windowsRead, "windows": windowEvidence, "applicationChildrenAttribute": applicationChildrenRead,
        "focusedWindow": focused, "ownedWindowEstablished": ownedWindowEstablished, "nodes": rows,
        "traversal": ["depthLimit": 24, "nodeLimit": 2500, "maximumDepth": maximumDepth,
                      "depthTruncated": depthTruncated, "nodeTruncated": nodeTruncated,
                      "deduplicatedNodeCount": nodes.count, "childrenReads": childReads, "unexpectedErrors": traversalErrors]]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
case "activate":
    _ = identity()
    let started = Date().timeIntervalSince1970
    let requested = running.activate()
    let deadline = Date(timeIntervalSinceNow: 3)
    while requested && !running.isActive && deadline.timeIntervalSinceNow > 0 {
        _ = identity()
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    _ = identity()
    let outcome: [String: Any] = ["pid": pid, "requestedAtEpochSeconds": started,
        "requestReturned": requested, "activeAfterBoundedWait": running.isActive,
        "finishedAtEpochSeconds": Date().timeIntervalSince1970, "waitBudgetSeconds": 3]
    print(String(decoding: try JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys]), as: UTF8.self))
case "snapshot":
    guard let root = environment["SHEPHERD_OWNED_OPERATOR_ROOT"], let domain = environment["OWNED_OPERATOR_DEFAULTS_DOMAIN"] else { fail("Validated private snapshot channel required") }
    let canonical = try OwnedOperatorPaths.existing(root)
    try OwnedOperatorPaths.owned(canonical, type: .typeDirectory, mode: 0o700)
    let marker = try OwnedOperatorPaths.descendant(canonical + "/owned-operator.json", root: canonical)
    try OwnedOperatorPaths.owned(marker, type: .typeRegular, mode: 0o600)
    let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: marker))) as? [String: Any]
    guard input?["defaultsDomain"] as? String == domain else { fail("Private snapshot domain mismatch") }
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(domain + ".window-snapshot"), object: domain, userInfo: nil, deliverImmediately: true)
case "press":
    guard ownedWindowEstablished else { fail("No positively established owned AXWindow; refusing AXPress") }
    guard arguments.count == 5 else { fail("press requires exact AX role and title/description") }
    let role = arguments[3], label = arguments[4]
    let matches = nodes.filter { string($0, kAXRoleAttribute) == role && (string($0, kAXTitleAttribute) == label || string($0, kAXDescriptionAttribute) == label) }
    guard matches.count == 1 else { fail("Expected exactly one owned AX element; found \(matches.count): \(role) \(label)") }
    let error = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
    guard error == .success else { fail("Owned AXPress failed: \(error.rawValue)") }
case "type":
    guard ownedWindowEstablished else { fail("No positively established owned AXWindow; refusing input") }
    guard arguments.count == 5, arguments[3].utf16.count <= 512 else { fail("type requires bounded text and exact focused role") }
    running.activate()
    for _ in 0..<50 { if running.isActive { break }; usleep(20_000) }
    for character in arguments[3].utf16 {
        _ = identity()
        guard running.isActive,
              let window = attribute(application, kAXFocusedWindowAttribute),
              let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
              windows.contains(where: { CFEqual($0, window) }),
              let focused = attribute(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { fail("Owned active window/focus cannot be proved") }
        let control = unsafeDowncast(focused, to: AXUIElement.self)
        guard string(control, kAXRoleAttribute) == arguments[4] else { fail("Unexpected owned focused control role: " + string(control, kAXRoleAttribute)) }
        let code: CGKeyCode = character == 10 ? 36 : 0
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { fail("Could not create targeted event") }
            if character != 10 { var value = character; event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value) }
            event.postToPid(pid)
        }
        usleep(10_000)
    }
case "quit":
    guard running.terminate() else { fail("Owned normal termination request refused") }
    var restore: [String: Any] = ["attempted": false, "identityMatched": false]
    if let previousData = environment["OWNED_OPERATOR_PREVIOUS_FRONT_IDENTITY"]?.data(using: .utf8),
       let previous = try? JSONDecoder().decode([String: String].self, from: previousData),
       let previousPID = previous["pid"].flatMap(Int32.init), previousPID != pid,
       let current = processIdentity(previousPID), current == previous,
       let prior = NSRunningApplication(processIdentifier: previousPID) {
        restore = ["attempted": true, "identityMatched": true, "pid": previousPID, "requestReturned": prior.activate()]
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: restore, options: [.sortedKeys]), as: UTF8.self))
default: fail("Unknown owned AX operation")
}
