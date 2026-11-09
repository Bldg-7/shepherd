// swift-tools-version: 6.2

// The parts of Shepherd that don't depend on a platform: talking to herdr
// (over this Mac's socket or SSH), the machines and their credentials, the
// monitors that keep a machine's board up to date, and the agent event
// contract the notifications are made from. The macOS app depends on it,
// and so will the iOS app (docs/mobile-design.md, section 8).
//
// The compiler settings mirror the app target's: Swift 6 language mode with
// approachable concurrency, and MainActor as the default isolation — the
// sources were written against those, and say `nonisolated` where they
// mean it.
import PackageDescription

// The historical SDK is an explicit fixture product, never a dependency of
// ShepherdKit. Shared models, pinned SSH primitives and archive readers stay
// in the normal product; executable legacy backends live only in this list.
let legacyFixtureSources = [
    "HerdrKit/HerdrClient.swift",
    "HerdrKit/Models/HerdrMessage.swift",
    "HerdrKit/Models/HerdrSubscription.swift",
    "HerdrKit/Transport/ConversationSSHLineChannel.swift",
    "HerdrKit/HerdrMachineSetup",
    "HerdrKit/Live",
    "HerdrKit/Terminal/HerdrExecutable.swift",
    "HerdrKit/Terminal/TerminalSession.swift",
    "HerdrKit/Transport/HerdrTransport.swift",
    "HerdrKit/Transport/LocalHerdrTransport.swift",
    "HerdrKit/Transport/SSHHerdrTransport.swift",
    "Machines/MachineMonitor.swift",
    "Machines/MachineMonitors.swift",
    "Machines/MachineStore+Transport.swift",
]
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
        .library(name: "ShepherdKit", targets: ["ShepherdKit"]),
        .library(name: "ShepherdLegacyFixtures", targets: ["ShepherdLegacyFixtures"])
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
            exclude: legacyFixtureSources,
            resources: [
                .process("Resources")
            ],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "ShepherdLegacyFixtures",
            dependencies: [
                "ShepherdKit",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/ShepherdKit",
            exclude: ["Resources"],
            sources: legacyFixtureSources,
            swiftSettings: sharedSwiftSettings + [.define("SHEPHERD_LEGACY_FIXTURE_MODULE")]
        )
    ],
    swiftLanguageModes: [.v6]
)
