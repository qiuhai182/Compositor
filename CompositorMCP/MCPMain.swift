import Foundation
import MCP

/// The compositor-mcp entry point: a headless MCP server over local Streamable HTTP.
///
/// It hosts the same editing core as the Compositor app without any UI, so AI agents can create
/// and edit .comp projects. The app can later embed the same tool set (see docs/mcp-server.md).
@main
struct MCPMain {
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
                compositor-mcp — Compositor as an MCP server

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

        let handlers = MCPToolHandlers()
        let transport = StatefulHTTPServerTransport()
        let server = await CompositorMCPServer.make(handlers: handlers)
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
