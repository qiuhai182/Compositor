#if !canImport(Network)
import Foundation
import NIOCore
import NIOPosix

/// The socket layer where Network.framework is missing (Windows, Linux): a swift-nio listener on
/// plain TCP, handing the bridge the same byte-stream connections the Apple transport does.
nonisolated final class NIOHTTPTransport: MCPHTTPTransport, @unchecked Sendable {
    private var group: MultiThreadedEventLoopGroup?
    private var server: Channel?
    private(set) var boundPort: UInt16?

    func start(host: String, port: UInt16,
               handler: @escaping @Sendable (any MCPHTTPConnection) async -> Void) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            let channel = try await ServerBootstrap(group: group)
                // Loopback by default; an explicit --host reaches other machines. Port 0 binds an
                // ephemeral port, which `boundPort` then reports.
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { child in
                    let connection = NIOConnection(channel: child)
                    // The pump must be in the pipeline before the first byte can arrive, so the
                    // bootstrap waits for it before making the connection live.
                    let installed = connection.installed
                    Task { await handler(connection) }
                    return installed
                }
                .bind(host: host, port: Int(port))
                .get()
            self.server = channel
            self.boundPort = channel.localAddress?.port.map { UInt16($0) }
        } catch {
            // Nothing is listening, so the event loop threads have nothing left to do.
            try? group.syncShutdownGracefully()
            self.group = nil
            throw error
        }
    }

    func stop() {
        // Non-blocking: the embedded server stops from the main actor, possibly while agents are
        // still connected, so nothing here waits on them.
        server?.close(promise: nil)
        server = nil
        group?.shutdownGracefully { _ in }
        group = nil
    }
}

/// One accepted channel as the byte stream the bridge's shared logic reads and writes.
private final class NIOConnection: MCPHTTPConnection, @unchecked Sendable {
    private let channel: Channel
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator
    /// Resolves once the byte pump is in the channel's pipeline.
    let installed: EventLoopFuture<Void>

    init(channel: Channel) {
        self.channel = channel
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        var iterator = stream.makeAsyncIterator()
        self.iterator = iterator
        self.installed = channel.pipeline.addHandler(BytePump(continuation: continuation))
    }

    func receive() async throws -> Data? {
        await iterator.next()
    }

    func send(_ data: Data, final: Bool) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.writeAndFlush(buffer).whenComplete { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        // One request per connection: the final write closes the socket, like the Apple
        // transport's final-message context does.
        if final {
            close()
        }
    }

    func close() {
        channel.close(promise: nil)
    }
}

/// Pumps socket bytes into the connection's stream; ends the stream when the socket closes.
private final class BytePump: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let data = buffer.readData(length: buffer.readableBytes), !data.isEmpty {
            continuation.yield(data)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
#endif
