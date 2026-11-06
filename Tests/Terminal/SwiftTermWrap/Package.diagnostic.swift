// swift-tools-version:6.0
// DERIVED DIAGNOSTIC MANIFEST: keep the actual SwiftTerm target/resources/plugin,
// omit unrelated Termcast/docs/benchmark dependencies; not a product pin change.
import PackageDescription
let package = Package(name:"SwiftTerm",platforms:[.macOS(.v11)],products:[.library(name:"SwiftTerm",targets:["SwiftTerm"])],targets:[
    .target(name:"SwiftTerm",path:"Sources/SwiftTerm",exclude:["Mac/README.md"],resources:[.process("Apple/Metal/Shaders.metal")],plugins:[.plugin(name:"SwiftTermBuildInfoPlugin")]),
    .executableTarget(name:"SwiftTermBuildInfoGenerator",path:"Sources/SwiftTermBuildInfoGenerator"),
    .plugin(name:"SwiftTermBuildInfoPlugin",capability:.buildTool(),dependencies:["SwiftTermBuildInfoGenerator"])
],swiftLanguageModes:[.v5])
