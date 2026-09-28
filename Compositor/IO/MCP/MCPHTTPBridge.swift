import Foundation
import MCP

/// One client connection as a byte stream, so the shared HTTP logic below runs on any socket
/// layer: Network.framework on Apple platforms (NWHTTPTransport), swift-nio elsewhere
/// (NIOHTTPTransport).
nonisolated protocol MCPHTTPConnection: Sendable {
    /// The next bytes from the socket; nil once the connection closed cleanly.
    func receive() async throws -> Data?
    /// Writes bytes to the socket; `final` also closes it, as this server keeps one request per
    /// connection.
    func send(_ data: Data, final: Bool) async throws
}

/// The listener under `MCPHTTPBridge`: binds the host and port, then hands every connection to
/// the bridge's handler.
nonisolated protocol MCPHTTPTransport: Sendable {
    /// Binds and starts accepting. Returns once the port is listening; `boundPort` then holds the
    /// port actually bound, which matters when binding port 0 for an ephemeral port.
    func start(host: String, port: UInt16,
               handler: @escaping @Sendable (any MCPHTTPConnection) async -> Void) async throws
    func stop()
    var boundPort: UInt16? { get }
}

/// Serves the MCP transport over a plain local HTTP listener on whichever socket layer the
/// platform has.
///
/// The MCP swift-sdk transports are framework-agnostic: they turn `HTTPRequest` values into
/// `HTTPResponse` values and leave the socket work to the host. This bridge is that host. One
/// request per connection (`Connection: close`) keeps the parser simple; SSE responses stream
/// until the transport ends the stream and the socket closes.
nonisolated final class MCPHTTPBridge: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let path: String
    private let token: String?
    private let transport: StatefulHTTPServerTransport
    private let server: Server
    private let socket: any MCPHTTPTransport

    init(host: String = "127.0.0.1", port: UInt16, path: String, token: String? = nil,
         transport: StatefulHTTPServerTransport, server: Server) {
        self.host = host
        self.port = port
        self.path = path
        self.token = token
        self.transport = transport
        self.server = server
        self.socket = Self.makeSocket()
    }

    /// Network.framework where it exists; swift-nio everywhere else.
    private static func makeSocket() -> any MCPHTTPTransport {
        #if canImport(Network)
        NWHTTPTransport()
        #else
        NIOHTTPTransport()
        #endif
    }

    /// The port actually listening, once `run` has started the socket.
    var boundPort: UInt16? { socket.boundPort }

    /// Starts the MCP server and the HTTP listener. Throws when the port is taken or a remote
    /// host was requested without a token.
    func run() async throws {
        if !Self.isLoopback(host), token == nil {
            throw MCPError.internalError("Binding to \(host) exposes the server beyond this machine; pass --token (or COMPOSITOR_MCP_TOKEN) so only agents holding it can connect.")
        }
        try await server.start(transport: transport)
        try await socket.start(host: host, port: port) { [weak self] connection in
            await self?.handle(connection)
        }
        let reported = socket.boundPort ?? port
        FileHandle.standardError.write(Data("compositor-mcp: listening on http://127.0.0.1:\(reported)\(path)\n".utf8))
    }

    func stop() {
        socket.stop()
    }

    // MARK: - Request handling

    private func handle(_ connection: any MCPHTTPConnection) async {
        defer { connection.close() }
        do {
            guard let request = try await readRequest(connection) else { return }
            guard request.path == nil || request.path == path else {
                try await sendSimple(connection, status: 404, reason: "Not Found", body: "Not Found\n")
                return
            }
            // Bearer authentication: whoever reaches beyond loopback has to hold the token.
            if let token {
                guard request.header("authorization") == "Bearer \(token)" else {
                    try await sendSimple(connection, status: 401, reason: "Unauthorized", body: "Unauthorized\n")
                    return
                }
            }
            let response = await transport.handleRequest(request)
            try await send(connection, response)
        } catch {
            // A dropped connection mid-request is ordinary; anything else is worth a line on stderr.
            if !(error is CancellationError) {
                FileHandle.standardError.write(Data("compositor-mcp: \(error)\n".utf8))
            }
        }
    }

    /// Reads one HTTP/1.1 request head plus its Content-Length body. Nil when the socket closed first.
    private func readRequest(_ connection: any MCPHTTPConnection) async throws -> HTTPRequest? {
        var buffer = Data()
        let headEnd = Data("\r\n\r\n".utf8)
        // The head.
        while buffer.range(of: headEnd) == nil {
            guard let chunk = try await connection.receive() else { return nil }
            buffer.append(chunk)
            guard buffer.count <= 1_048_576 else { throw MCPError.parseError("HTTP head too large") }
        }
        guard let headRange = buffer.range(of: headEnd) else { return nil }
        let head = String(decoding: buffer[..<headRange.lowerBound], as: UTF8.self)
        var body = Data(buffer[headRange.upperBound...])

        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).makeIterator()
        guard let requestLine = lines.next() else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3 else { throw MCPError.parseError("Malformed request line") }
        let method = String(parts[0])
        let rawPath = String(parts[1])

        // Lowercased keys: the transport looks headers up case-insensitively; the bridge does not.
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // The body, when there is one.
        let declared = headers["content-length"].flatMap { Int($0) } ?? 0
        guard declared <= 33_554_432 else { throw MCPError.parseError("Request body too large") }
        while body.count < declared {
            guard let chunk = try await connection.receive() else { return nil }
            body.append(chunk)
        }
        return HTTPRequest(method: method, headers: headers, body: body.prefix(declared), path: rawPath)
    }

    // MARK: - Response writing

    private func send(_ connection: any MCPHTTPConnection, _ response: HTTPResponse) async throws {
        switch response {
        case .data(let data, let headers):
            try await sendHead(connection, status: 200, reason: "OK", headers: headers, contentLength: data.count)
            try await connection.send(data, final: true)
        case .ok(let headers):
            try await sendHead(connection, status: 200, reason: "OK", headers: headers, contentLength: 0)
            try await connection.send(Data(), final: true)
        case .accepted(let headers):
            try await sendHead(connection, status: 202, reason: "Accepted", headers: headers, contentLength: 0)
            try await connection.send(Data(), final: true)
        case .error(let status, _, _, let extraHeaders):
            let body = response.bodyData ?? Data()
            var headers = extraHeaders
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            try await sendHead(connection, status: status, reason: Self.reason(for: status), headers: headers, contentLength: body.count)
            try await connection.send(body, final: true)
        case .stream(let stream, let headers):
            var sent = headers
            sent["Content-Type"] = sent["Content-Type"] ?? "text/event-stream"
            sent["Cache-Control"] = "no-cache"
            sent["Connection"] = "close"
            var head = "HTTP/1.1 200 OK\r\n"
            for (name, value) in sent { head += "\(name): \(value)\r\n" }
            head += "\r\n"
            try await connection.send(Data(head.utf8), final: false)
            // The transport hands over SSE-formatted frames; pass the bytes through.
            for try await frame in stream {
                try Task.checkCancellation()
                try await connection.send(frame, final: false)
            }
            try await connection.send(Data(), final: true)
        }
    }

    private func sendSimple(_ connection: any MCPHTTPConnection, status: Int, reason: String, body: String) async throws {
        let data = Data(body.utf8)
        try await sendHead(connection, status: status, reason: reason,
                           headers: ["Content-Type": "text/plain"], contentLength: data.count)
        try await connection.send(data, final: true)
    }

    private func sendHead(_ connection: any MCPHTTPConnection, status: Int, reason: String,
                          headers: [String: String], contentLength: Int) async throws {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var sent = headers
        sent["Content-Length"] = "\(contentLength)"
        sent["Connection"] = "close"
        for (name, value) in sent { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        try await connection.send(Data(head.utf8), final: false)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}
