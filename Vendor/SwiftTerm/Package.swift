// swift-tools-version:6.0
// Pinned production-library subset of SwiftTerm1.20.0. See PROVENANCE.md.
import PackageDescription
import Foundation

let excludeApple = ProcessInfo.processInfo.environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
let resources: [Resource] = []
#else
let platformExcludes: [String] = excludeApple ? ["Apple", "Mac", "iOS"] : []
let resources: [Resource] = excludeApple ? [] : [.process("Apple/Metal/Shaders.metal")]
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", path: "Sources/SwiftTerm",
                exclude: platformExcludes + ["Mac/README.md"], resources: resources),
        .testTarget(name: "SwiftTermTests", dependencies: ["SwiftTerm"],
                    resources: [.copy("Fixtures/xterm-ghostty.infocmp"),
                                .copy("Fixtures/swifterm-terminfo.infocmp")])
    ],
    // Preserve upstream's dependency language mode. Shepherd stays Swift6/strict.
    swiftLanguageModes: [.v5]
)
