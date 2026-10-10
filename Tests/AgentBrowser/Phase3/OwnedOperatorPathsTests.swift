import Foundation

@main struct OwnedOperatorPathsTests {
    static func main() throws {
        let manager = FileManager.default
        let path = "/tmp/shepherd-operator-path-test-" + UUID().uuidString
        try manager.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let sibling = path + "-sibling"
        try manager.createDirectory(atPath: sibling, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(atPath: path); try? manager.removeItem(atPath: sibling) }
        let root = try OwnedOperatorPaths.existing(path)
        let alias = try OwnedOperatorPaths.existing("/private" + path)
        let trailing = try OwnedOperatorPaths.existing(path + "/")
        precondition(alias == root && trailing == root)
        precondition(!OwnedOperatorPaths.isInside(root + "-sibling", root: root))
        try manager.createSymbolicLink(atPath: path + "/escape", withDestinationPath: sibling)
        do { _ = try OwnedOperatorPaths.descendant(path + "/escape", root: root); fatalError("symlink escape admitted") }
        catch is POSIXError {}
        do { _ = try OwnedOperatorPaths.existing(path + "/missing"); fatalError("failed resolution admitted") }
        catch is POSIXError {}
        let output = try OwnedOperatorPaths.descendant(path + "/output.json", root: root, allowMissingLeaf: true)
        precondition(output == root + "/output.json")
        do { _ = try OwnedOperatorPaths.descendant(path + "/missing-parent/output", root: root, allowMissingLeaf: true); fatalError("nonexisting parent admitted") }
        catch is POSIXError {}
        try manager.createSymbolicLink(atPath: path + "/dangling", withDestinationPath: sibling + "/missing")
        do { _ = try OwnedOperatorPaths.descendant(path + "/dangling", root: root, allowMissingLeaf: true); fatalError("dangling symlink admitted") }
        catch is POSIXError {}
        try OwnedOperatorPaths.owned(root, type: .typeDirectory, mode: 0o700)
        print("PASS: tmp/private-tmp alias, trailing slash, sibling boundary, symlink escape, failed resolution, validated existing-parent output, dangling symlink, owned mode/type")
    }
}
