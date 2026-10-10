#if DEBUG && os(macOS)
import Foundation
import Darwin

/// POSIX canonical strings are intentional: Foundation URL normalization on
/// macOS may rewrite /private/tmp and retain directory-slash distinctions.
enum OwnedOperatorPaths {
    static func existing(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        guard let resolved = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
    static func descendant(_ path: String, root: String, allowMissingLeaf: Bool = false) throws -> String {
        let canonical: String
        var information = stat()
        if lstat(path, &information) == 0 {
            canonical = try existing(path)
        } else {
            guard errno == ENOENT, allowMissingLeaf else { throw POSIXError(.ENOENT) }
            let leaf = (path as NSString).lastPathComponent
            guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/"), !leaf.utf8.contains(0) else { throw POSIXError(.EINVAL) }
            let parent = try existing((path as NSString).deletingLastPathComponent)
            let attributes = try FileManager.default.attributesOfItem(atPath: parent)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw POSIXError(.ENOTDIR) }
            canonical = parent + "/" + leaf
        }
        guard isInside(canonical, root: root) else { throw POSIXError(.EPERM) }
        return canonical
    }
    static func owned(_ path: String, type: FileAttributeType, mode: Int? = nil) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              mode == nil || (attributes[.posixPermissions] as? NSNumber)?.intValue == mode else { throw POSIXError(.EPERM) }
    }
}
#endif
