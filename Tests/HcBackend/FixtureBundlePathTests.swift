import Foundation
import Darwin

@main private struct FixtureBundlePathTests {
    static func main() {
        do { try run() }
        catch { print("FAIL owned fixture bundle path: \(error)"); exit(1) }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appending(path:"owned-bundle-path-"+UUID().uuidString,directoryHint:.isDirectory)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("Owned UI.app").path
        try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true)
        let directory = URL(fileURLWithPath:path,isDirectory:true), fileHint = URL(fileURLWithPath:path,isDirectory:false)
        guard HcFixtureBundlePath.matches(directory,expected:fileHint) else { throw NSError(domain:"same bundle directory hint mismatch",code:1) }
        guard HcFixtureBundlePath.matches(fileHint,expected:directory) else { throw NSError(domain:"inverse directory hint mismatch",code:1) }
        guard !HcFixtureBundlePath.matches(nil,expected:directory) else { throw NSError(domain:"nil matched",code:1) }
        guard !HcFixtureBundlePath.matches(URL(string:"https://example.invalid"+directory.path),expected:directory) else { throw NSError(domain:"nonfile matched",code:1) }
        guard !HcFixtureBundlePath.matches(root.appending(path:"Other.app"),expected:directory) else { throw NSError(domain:"other bundle matched",code:1) }
        let alias = root.appending(path:"alias.app")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:directory)
        guard HcFixtureBundlePath.matches(alias,expected:directory) else { throw NSError(domain:"canonical own symlink mismatch",code:1) }
        guard !HcFixtureBundlePath.matches(URL(string:"file://unrelated-host"+directory.path),expected:directory) else { throw NSError(domain:"nonlocal file matched",code:1) }
        print("PASS owned fixture bundle path: 7 checks")
    }
}
