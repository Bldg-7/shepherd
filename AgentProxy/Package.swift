// swift-tools-version: 6.2

// The agent proxy: a program apart from the app that agents started from the
// New Tab launcher send their model API requests through, so that a copy of
// what they say can be shown on the iPhone and iPad (SHPHRD-105).
//
// - AgentProxyProtocol: what the app and the proxy say to each other over
//   `ap.sock` (newline-delimited JSON, as herdr's socket), where its files and
//   sockets are, and the frames the forwarder sends its recorder. Foundation
//   only, so the iOS app can share it.
// - AgentProxyCore: bounded in-memory capture and provider stream framing;
//   Foundation and system CryptoKit. Recorder integration is developed separately.
// - AgentProxyForwarder: the 127.0.0.1 listener that passes each request on
//   to api.anthropic.com or chatgpt.com as it came, the control socket, the
//   state folder and the recorder it starts and restarts.
// - hrdrhrdrhrdr-agent-proxy: the executable. With no arguments it is the
//   forwarder; `recorder` makes it the recorder the forwarder starts.
//
// The dependencies are the ones the app already resolves (swift-nio pinned at
// 2.103.0, swift-nio-ssl and swift-crypto), so adding this package to the
// project leaves Package.resolved as it is. Swift 5 language mode, like the
// app's other package; nothing here runs on the main actor.
import PackageDescription

let package = Package(
    name: "AgentProxy",
    platforms: [
        .macOS("26.6"),
        .iOS("17.0")
    ],
    products: [
        .library(name: "AgentProxyProtocol", targets: ["AgentProxyProtocol"]),
        .library(name: "AgentProxyCore", targets: ["AgentProxyCore"]),
        .library(name: "AgentProxyForwarder", targets: ["AgentProxyForwarder"]),
        .executable(name: "hrdrhrdrhrdr-agent-proxy", targets: ["AgentProxyTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.36.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3")
    ],
    targets: [
        .target(name: "AgentProxyProtocol"),
        .target(name: "AgentProxyCore"),
        .target(
            name: "AgentProxyForwarder",
            dependencies: [
                "AgentProxyProtocol",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .executableTarget(
            name: "AgentProxyTool",
            dependencies: ["AgentProxyForwarder", "AgentProxyProtocol"]
        )
    ],
    swiftLanguageModes: [.v5]
)
