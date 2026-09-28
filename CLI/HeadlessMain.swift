import Foundation
import MCP

/// The cross-platform compositor-mcp entry point: the same MCP server as the macOS app's
/// `MCPMain`, editing through Core's headless engine instead of an `EditorSession`, so it builds
/// and runs wherever Swift does (see docs/cross-platform.md).
///
/// Built by the SwiftPM package as the `compositor-mcp` executable (`swift run compositor-mcp`);
/// the macOS app keeps its own richer copy in CompositorMCP/.
@main
struct HeadlessMain {
    static func main() async {
        var host = "127.0.0.1"
        var port: UInt16 = 9666
        var path = "/mcp"
        var token = ProcessInfo.processInfo.environment["COMPOSITOR_MCP_TOKEN"]

        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--host":
                guard let value = arguments.next() else {
                    FileHandle.standardError.write(Data("compositor-mcp: --host needs a value\n".utf8))
                    exit(2)
                }
                host = value
            case "--port":
                guard let value = arguments.next(), let parsed = UInt16(value) else {
                    FileHandle.standardError.write(Data("compositor-mcp: --port needs a number\n".utf8))
                    exit(2)
                }
                port = parsed
            case "--path":
                guard let value = arguments.next() else {
                    FileHandle.standardError.write(Data("compositor-mcp: --path needs a value\n".utf8))
                    exit(2)
                }
                path = value.hasPrefix("/") ? value : "/" + value
            case "--token":
                guard let value = arguments.next() else {
                    FileHandle.standardError.write(Data("compositor-mcp: --token needs a value\n".utf8))
                    exit(2)
                }
                token = value
            case "--help", "-h":
                print("""
                compositor-mcp — Compositor as a headless MCP server

                Usage: compositor-mcp [--host 127.0.0.1] [--port 9666] [--path /mcp] [--token SECRET]

                Endpoints: http://<host>:<port><path> (MCP Streamable HTTP)
                Loopback by default; other hosts require --token (or COMPOSITOR_MCP_TOKEN),
                checked as a Bearer Authorization header.
                """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("compositor-mcp: unknown argument \(argument)\n".utf8))
                exit(2)
            }
        }

        let handlers = HeadlessMCPHandlers()
        let transport = StatefulHTTPServerTransport()
        let server = await HeadlessMCPServer.make(handlers: handlers)
        let bridge = MCPHTTPBridge(host: host, port: port, path: path, token: token,
                                   transport: transport, server: server)
        do {
            try await bridge.run()
        } catch {
            FileHandle.standardError.write(Data("compositor-mcp: \(error)\n".utf8))
            exit(1)
        }
        // Park; the listener's connection tasks and the main-actor editing work keep the process busy.
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
