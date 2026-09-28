#if canImport(Network)
import Foundation
import Network
import MCP

/// The socket layer on Apple platforms: a Network.framework listener handing plain TCP
/// connections to the bridge.
nonisolated final class NWHTTPTransport: MCPHTTPTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.wonderassembly.compositor.mcp.http")
    private var listener: NWListener?
    private(set) var boundPort: UInt16?

    func start(host: String, port: UInt16,
               handler: @escaping @Sendable (any MCPHTTPConnection) async -> Void) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback by default; an explicit --host reaches other machines. Port 0 binds an
        // ephemeral port, which `boundPort` then reports.
        guard let endpointHost = NWEndpoint.Host(host), let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPError.internalError("Invalid host or port: \(host):\(port)")
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: endpointHost, port: endpointPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, handler: handler)
        }
        // `start` returns only once the port is listening, so tests can talk to it right away.
        let gate = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    _ = gate.once { continuation.resume() }
                case .failed(let error):
                    if !gate.once({ continuation.resume(throwing: error) }) {
                        // A listener that dies while running leaves nothing to serve.
                        FileHandle.standardError.write(Data("compositor-mcp: listener failed: \(error)\n".utf8))
                        exit(1)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.boundPort = listener.port.map { UInt16($0.rawValue) }
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection,
                        handler: @escaping @Sendable (any MCPHTTPConnection) async -> Void) {
        connection.start(queue: queue)
        Task { await handler(NWConnectionHandle(connection: connection)) }
    }
}

/// Hands its body to the first caller only, so a listener state that fires more than once
/// cannot resume the `start` continuation twice.
private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    /// Runs `body` the first time only; true when it ran.
    func once(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        body()
        return true
    }
}

/// One NWConnection as the byte stream the bridge's shared logic reads and writes.
private final class NWConnectionHandle: MCPHTTPConnection, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func send(_ data: Data, final: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data,
                            contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: final,
                            completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func close() {
        connection.cancel()
    }
}
#endif
