// swift-tools-version: 6.0
// The cross-platform core of Compositor: the .comp model vocabulary (transforms, blend modes,
// canvas operations, document limits) with no Apple-framework dependencies. The macOS app and
// compositor-mcp compile the same files through the Xcode project; this package lets Windows and
// Linux build and test them too. See docs/cross-platform.md.
//
// MCPBridge carries the platform-neutral MCP slice: the HTTP bridge plus its socket transports
// (Network.framework on Apple platforms, swift-nio elsewhere), the shared tool helpers, and the
// headless tool handlers backed by Core's HeadlessProject. The compositor-mcp CLI builds them on
// all three platforms through the MCPCLI executable; the app's own MCP server keeps building
// through the Xcode project.
import PackageDescription

let package = Package(
    name: "CompositorCore",
    products: [
        .library(name: "CompositorCore", targets: ["CompositorCore"]),
        .executable(name: "compositor-mcp", targets: ["MCPCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
        .package(url: "https://github.com/tayloraswift/swift-png", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "CompositorCore",
            dependencies: [.product(name: "PNG", package: "swift-png")],
            path: "Core"),
        .target(
            name: "MCPBridge",
            dependencies: [
                .target(name: "CompositorCore"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Compositor/IO/MCP",
            sources: ["MCPHTTPBridge.swift", "MCPHTTPNetworkTransport.swift", "MCPHTTPNIOTransport.swift",
                      "MCPToolSupport.swift", "HeadlessMCPHandlers.swift", "HeadlessMCPServer.swift"]),
        .executableTarget(
            name: "MCPCLI",
            dependencies: ["MCPBridge", "CompositorCore"],
            path: "CLI"),
        .testTarget(name: "CompositorCoreTests", dependencies: ["CompositorCore"], path: "CoreTests"),
    ]
)
