import Foundation
import Testing
import MCP
@testable import Compositor

/// The HTTP bridge over a real loopback socket, met exactly as an agent's MCP client would meet
/// it: JSON-RPC in, JSON-RPC out, and the token gate in between.
@MainActor
struct MCPHTTPBridgeTests {
    private func post(_ body: String, to port: UInt16, token: String?) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    @Test func loopbackInitializeAndTokenGate() async throws {
        let transport = StatefulHTTPServerTransport()
        let server = await CompositorMCPServer.make(handlers: MCPToolHandlers())
        // Port 0 binds an ephemeral port, so concurrent test runs never collide; `boundPort`
        // reports what actually came up.
        let bridge = MCPHTTPBridge(port: 0, path: "/mcp", token: "test-token",
                                   transport: transport, server: server)
        try await bridge.run()
        defer { bridge.stop() }
        let port = try #require(bridge.boundPort)

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"loopback-test","version":"0"}}}"#

        // Without the token the bridge refuses the request before the MCP server sees it.
        let refused = try await post(initialize, to: port, token: nil)
        #expect(refused.status == 401)

        // With it, the server answers initialize over HTTP.
        let accepted = try await post(initialize, to: port, token: "test-token")
        #expect(accepted.status == 200)
        #expect(accepted.body.contains(#""jsonrpc":"2.0""#))
        #expect(accepted.body.contains(#""serverInfo""#))
    }
}
