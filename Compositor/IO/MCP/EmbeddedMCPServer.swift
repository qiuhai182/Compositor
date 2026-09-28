import AppKit
import MCP
import Observation

/// The MCP server hosted inside the app: the same tool catalog as compositor-mcp, running while
/// Compositor is open. Off by default; View > MCP Server toggles it, and a launch-time default
/// (`MCPEnabled`) turns it on automatically. Agents edit in their own sessions and save into .comp
/// packages, so an open project follows along through the usual live reload.
@MainActor
@Observable
final class EmbeddedMCPServer {
    static let shared = EmbeddedMCPServer()

    private(set) var isRunning = false
    private var bridge: MCPHTTPBridge?
    private var handlers: MCPToolHandlers?

    static var isEnabledByDefault: Bool { UserDefaults.standard.bool(forKey: "MCPEnabled") }
    static var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "MCPPort")
        return (1...65535).contains(stored) ? UInt16(stored) : 9666
    }

    func start() {
        guard !isRunning else { return }
        Task {
            let handlers = MCPToolHandlers()
            let transport = StatefulHTTPServerTransport()
            let server = await CompositorMCPServer.make(handlers: handlers)
            let bridge = MCPHTTPBridge(port: Self.port, path: "/mcp", transport: transport, server: server)
            do {
                try await bridge.run()
            } catch {
                // Almost always the port is taken by another Compositor or the CLI server.
                NSLog("Compositor MCP server could not start: \(error.localizedDescription)")
                return
            }
            self.bridge = bridge
            self.handlers = handlers
            isRunning = true
        }
    }

    func stop() {
        guard isRunning else { return }
        bridge?.stop()
        bridge = nil
        handlers = nil
        isRunning = false
    }
}
