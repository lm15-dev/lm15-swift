#if os(Linux)
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL

/// Native Linux WebSocket transport with verified TLS, bounded message buffering and cancellation.
public final class NIOLiveSocket: LiveSocket, Sendable {
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads:1)
    private let bridge: SocketBridge
    private init(_ bridge: SocketBridge) { self.bridge = bridge }
    public static func connect(_ request: TransportRequest, maxMessageBytes: Int = 16_777_216) async throws -> NIOLiveSocket {
        guard let url = URLComponents(string:request.url), let host = url.host, ["ws","wss"].contains(url.scheme ?? ""), url.user == nil, url.password == nil, url.fragment == nil, maxMessageBytes > 0, maxMessageBytes <= 64*1024*1024, request.timeout.isFinite, request.timeout > 0, request.timeout <= 3600 else { throw ValueError("invalid WebSocket request or limits") }
        let secure = url.scheme == "wss", port = url.port ?? (url.scheme == "wss" ? 443 : 80), bridge = SocketBridge(limit:maxMessageBytes)
        let tls = secure ? try NIOSSLContext(configuration:.makeClientConfiguration()) : nil
        var headers = HTTPHeaders(); for (key,value) in request.headers.o { headers.add(name:key,value:value.s) }
        headers.replaceOrAdd(name:"host",value:(host.contains(":") ? "[\(host)]" : host)+(url.port.map { ":\($0)" } ?? "")); headers.replaceOrAdd(name:"content-length",value:"0")
        let head = HTTPRequestHead(version:.http1_1,method:.GET,uri:(url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath)+(url.percentEncodedQuery.map { "?"+$0 } ?? ""),headers:headers)
        return try await withTaskCancellationHandler {
            do {
                let negotiated: EventLoopFuture<Channel> = try await ClientBootstrap(group:group).connectTimeout(.milliseconds(Int64(request.timeout*1000))).connect(host:host,port:port) { channel in
                    bridge.install(channel)
                    return channel.eventLoop.makeCompletedFuture {
                        if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context:tls,serverHostname:host)) }
                        let upgrader = NIOTypedWebSocketClientUpgrader<Channel>(maxFrameSize:maxMessageBytes,enableAutomaticErrorHandling:false,upgradePipelineHandler:{ channel,_ in
                            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(SocketFrames(bridge:bridge,limit:maxMessageBytes)); return channel }
                        })
                        let config = NIOTypedHTTPClientUpgradeConfiguration<Channel>(upgradeRequestHead:head,upgraders:[upgrader],notUpgradingCompletionHandler:{ channel in channel.eventLoop.makeFailedFuture(TransportError("WebSocket upgrade refused")) })
                        let future = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(configuration:.init(upgradeConfiguration:config))
                        let timeout = channel.eventLoop.scheduleTask(in:.milliseconds(Int64(request.timeout*1000))) { bridge.finish(TimeoutError("WebSocket handshake timed out")); channel.close(promise:nil) }
                        future.whenComplete { _ in timeout.cancel() }; return future
                    }
                }
                _ = try await negotiated.get(); try Task.checkCancellation(); return NIOLiveSocket(bridge)
            } catch { bridge.close(); if Task.isCancelled { throw CancellationError() }; if let error = error as? LM15Error { throw error }; throw TransportError("WebSocket connection failed") }
        } onCancel: { bridge.close() }
    }
    public func send(_ data: Data) async throws {
        guard String(data:data,encoding:.utf8) != nil, data.count <= bridge.limit else { throw ValueError("invalid or oversized UTF-8 live frame") }
        let channel = try bridge.activeChannel()
        do { try await withTaskCancellationHandler { try await channel.writeAndFlush(WebSocketFrame(fin:true,opcode:.text,maskKey:.random(),data:ByteBuffer(bytes:data))).get() } onCancel: { bridge.close() } }
        catch { if Task.isCancelled { throw CancellationError() }; throw TransportError("WebSocket send failed") }
    }
    public func receive() async throws -> Data? { try await withTaskCancellationHandler { try await bridge.next() } onCancel: { bridge.close() } }
    public func close() { bridge.close() }
    deinit { close() }
}
private final class SocketBridge: @unchecked Sendable {
    let lock = NSLock(), limit: Int
    var channel: Channel?, queue: [Data] = [], queuedBytes = 0, ended = false, failure: (any Error)?
    var waiter: CheckedContinuation<Data?,any Error>?
    init(limit: Int) { self.limit = limit }
    func install(_ channel: Channel) { let close = lock.withLock { self.channel = channel; return ended }; if close { channel.close(promise:nil) } }
    func activeChannel() throws -> Channel { try lock.withLock { guard !ended, let channel else { throw TransportError("WebSocket is closed") }; return channel } }
    func push(_ data: Data) throws {
        lock.lock()
        if ended { lock.unlock(); return }
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning:data); return }
        guard queuedBytes+data.count <= limit && queue.count < 1024 else { lock.unlock(); throw TransportError("live consumer exceeded receive buffer") }
        queue.append(data); queuedBytes += data.count; lock.unlock()
    }
    func next() async throws -> Data? { try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if !queue.isEmpty { let data = queue.removeFirst(); queuedBytes -= data.count; lock.unlock(); continuation.resume(returning:data) }
        else if ended { let error = failure; lock.unlock(); if let error { continuation.resume(throwing:error) } else { continuation.resume(returning:nil) } }
        else if waiter != nil { lock.unlock(); continuation.resume(throwing:TransportError("WebSocket already has an active receiver")) }
        else { waiter = continuation; lock.unlock() }
    } }
    func finish(_ error: (any Error)?) { lock.lock(); if ended { lock.unlock(); return }; ended = true; failure = error; let waiting = waiter; waiter = nil; lock.unlock(); if let error { waiting?.resume(throwing:error) } else { waiting?.resume(returning:nil) } }
    func close() { finish(nil); let channel = lock.withLock { let channel = self.channel; self.channel = nil; queue.removeAll(); queuedBytes = 0; return channel }; channel?.close(promise:nil) }
}
/// State is confined to the channel event loop; SocketBridge synchronizes async callers.
private final class SocketFrames: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let bridge: SocketBridge, limit: Int
    var partial = Data(), fragmented: WebSocketOpcode?, closed = false
    init(bridge: SocketBridge, limit: Int) { self.bridge = bridge; self.limit = limit }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        do {
            guard frame.maskKey == nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else { throw TransportError("invalid server WebSocket frame") }
            let bytes = Data(frame.data.readableBytesView)
            switch frame.opcode {
            case .ping,.pong,.connectionClose:
                guard frame.fin && bytes.count <= 125 else { throw TransportError("invalid WebSocket control frame") }
                if frame.opcode == .ping { context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin:true,opcode:.pong,maskKey:.random(),data:frame.data)),promise:nil) }
                if frame.opcode == .connectionClose {
                    if bytes.count == 1 { throw TransportError("invalid WebSocket close frame") }
                    if bytes.count >= 2 { let code = Int(bytes[0])*256+Int(bytes[1]); guard (1000...4999).contains(code), ![1004,1005,1006,1015].contains(code), !(1016...2999).contains(code), String(data:bytes.dropFirst(2),encoding:.utf8) != nil else { throw TransportError("invalid WebSocket close status") } }
                    closed = true; bridge.finish(nil); context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin:true,opcode:.connectionClose,maskKey:.random(),data:frame.data)),promise:nil); context.close(promise:nil)
                }
            case .text,.binary,.continuation:
                if frame.opcode == .continuation { guard fragmented != nil else { throw TransportError("unexpected WebSocket continuation") } }
                else { guard fragmented == nil else { throw TransportError("interleaved WebSocket messages") }; fragmented = frame.opcode }
                guard partial.count+bytes.count <= limit else { throw TransportError("WebSocket message exceeded limit") }; partial.append(bytes)
                if frame.fin { if fragmented == .text && String(data:partial,encoding:.utf8) == nil { throw TransportError("invalid WebSocket UTF-8") }; try bridge.push(partial); partial.removeAll(keepingCapacity:false); fragmented = nil }
            default: throw TransportError("unknown WebSocket opcode")
            }
        } catch { bridge.finish(error); context.close(promise:nil) }
    }
    func channelInactive(context: ChannelHandlerContext) { bridge.finish(closed ? nil : TransportError("WebSocket closed without a close frame")); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { bridge.finish(TransportError("WebSocket protocol or transport failure")); context.close(promise:nil) }
}
#endif

public func connectLiveSocket(_ request: TransportRequest) async throws -> any LiveSocket {
    #if os(Linux)
    return try await NIOLiveSocket.connect(request)
    #else
    return try URLSessionLiveSocket(request:request)
    #endif
}
