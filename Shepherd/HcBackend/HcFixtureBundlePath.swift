import Foundation

/// Fixture path equivalence only, NOT process/native/browser authorization.
/// Callers must separately own the process and verify its tested executable.
nonisolated enum HcFixtureBundlePath {
    static func matches(_ observed: URL?, expected: URL) -> Bool {
        guard let observed, observed.isFileURL, expected.isFileURL,
              [nil, "", "localhost"].contains(observed.host), [nil, "", "localhost"].contains(expected.host) else { return false }
        // Foundation URL equality also compares its directory hint/trailing
        // slash. LaunchServices and appending(path:) may disagree on that hint
        // for the exact same bundle; compare canonical local file paths only.
        return observed.standardizedFileURL.resolvingSymlinksInPath().path
            == expected.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
