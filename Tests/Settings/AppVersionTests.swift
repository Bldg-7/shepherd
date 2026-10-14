import Foundation

@main @MainActor enum AppVersionTests {
    static var checks = 0
    static func check(_ b: Bool) { precondition(b); checks += 1 }
    static func version(_ info: [String: Any]?, debug: Bool) -> String {
        AppVersion(infoDictionary: info, isDebug: debug).displayString
    }
    static func main() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.3.1", "CFBundleVersion": "26"]
        check(version(info, debug: true) == "0.3.1 (26) - debug")
        check(version(info, debug: false) == "0.3.1 (26)")
        check(version(nil, debug: false) == "? (?)")
        check(version([:], debug: true) == "? (?) - debug")
        check(version(["CFBundleShortVersionString": "0.3.1"], debug: false) == "0.3.1 (?)")
        check(version(["CFBundleVersion": "26"], debug: false) == "? (26)")
        check(version(["CFBundleShortVersionString": 0.3, "CFBundleVersion": 26], debug: false) == "? (?)")
        check(version(["CFBundleShortVersionString": "0.3.1", "CFBundleVersion": 26], debug: true) == "0.3.1 (?) - debug")
        // The runner builds this file twice, with and without DEBUG, and
        // says which; both binaries carry its Info.plist, as the app does.
        let mode = CommandLine.arguments.dropFirst().first
        precondition(mode == "debug" || mode == "release")
        let current = AppVersion.current
        check(current.isDebug == (mode == "debug"))
        check(current.version == "9.8.7" && current.build == "65")
        check(current.displayString == (mode == "debug" ? "9.8.7 (65) - debug" : "9.8.7 (65)"))
        print("PASS \(checks) version display checks, \(mode!) build")
    }
}
