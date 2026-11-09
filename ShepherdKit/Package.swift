// swift-tools-version: 6.2

// The parts of Shepherd that don't depend on a platform: talking to hc
// (over this Mac's process pipes or SSH), the machines and their
// credentials, pairing, and the archive readers. The macOS and iOS apps
// both depend on it.
//
// The compiler settings mirror the app target's: Swift 6 language mode with
// approachable concurrency, and MainActor as the default isolation — the
// sources were written against those, and say `nonisolated` where they
// mean it.
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
    name: "ShepherdKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.6"),
        .iOS("17.0")
    ],
    products: [
        .library(name: "ShepherdKit", targets: ["ShepherdKit"])
    ],
    dependencies: [
        .package(path: "../AgentProxy"),
        .package(path: "../Vendor/Citadel"),
        .package(path: "../Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(
            name: "ShepherdKit",
            dependencies: [
                .product(name: "AgentProxyCore", package: "AgentProxy"),
                .product(name: "AgentProxyProtocol", package: "AgentProxy"),
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: sharedSwiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
