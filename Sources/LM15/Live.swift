import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injectable bidirectional transport. Implementations must unblock receive when closed.
public protocol LiveSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close()
}
public typealias LiveConnector = @Sendable (TransportRequest) async throws -> any LiveSocket
public final class URLSessionLiveSocket: LiveSocket, Sendable {
    let session: URLSession, task: URLSessionWebSocketTask
    public init(request: TransportRequest, maxMessageBytes: Int = 16_777_216) throws {
        guard maxMessageBytes > 0 else { throw ValueError("WebSocket message limit must be positive") }
        session = URLSession(configuration:.ephemeral)
        task = session.webSocketTask(with:try request.urlRequest()); task.maximumMessageSize = maxMessageBytes; task.resume()
    }
    public func send(_ data: Data) async throws {
        guard let text = String(data:data,encoding:.utf8) else { throw ValueError("live frame must be UTF-8") }
        do { try await task.send(.string(text)) } catch { if Task.isCancelled { throw CancellationError() }; throw TransportError("WebSocket send failed") }
    }
    public func receive() async throws -> Data? {
        do { switch try await task.receive() { case .data(let bytes): return bytes; case .string(let text): return Data(text.utf8); @unknown default: throw TransportError("unsupported WebSocket message") } }
        catch { if Task.isCancelled { throw CancellationError() }; if task.closeCode == .normalClosure || task.closeCode == .goingAway { return nil }; throw TransportError("WebSocket receive failed") }
    }
    public func close() { task.cancel(with:.normalClosure,reason:nil); session.invalidateAndCancel() }
    deinit { close() }
}
private actor SendGate {
    var locked = false, waiting: [CheckedContinuation<Void,Never>] = []
    func acquire() async { if !locked { locked = true; return }; await withCheckedContinuation { waiting.append($0) } }
    func release() { if waiting.isEmpty { locked = false } else { waiting.removeFirst().resume() } }
}
public actor LiveSession: AsyncSequence {
    public typealias Element = LiveServerEvent
    public nonisolated let provider: String
    let socket: any LiveSocket, lm: ProviderLM, config: LiveConfig
    private var pending: [LiveServerEvent] = [], closed = false, receiving = false
    private let sendGate = SendGate()
    init(socket: any LiveSocket, lm: ProviderLM, config: LiveConfig) { self.socket = socket; self.lm = lm; self.config = config; provider = lm.provider }
    public func send(_ event: LiveClientEvent) async throws {
        await sendGate.acquire()
        do {
            try Task.checkCancellation(); if closed { throw TransportError("live session is closed") }
            for frame in try lm.encodeLiveEvent(event,config:config) { try await socket.send(frame.jsonData()) }
            await sendGate.release()
        } catch { await sendGate.release(); throw error }
    }
    public func sendText(_ text: String) async throws { try await send(.text(LiveClientTextEvent(text:text))) }
    public func sendTurn(_ parts: [PromptPart], turnComplete: Bool = true) async throws { try await send(.turn(LiveClientTurnEvent(parts:parts,turnComplete:turnComplete))) }
    public func sendAudio(_ bytes: Data, mediaType: String = "audio/pcm;rate=16000") async throws { try await send(.audio(LiveClientAudioEvent(data:bytes.base64EncodedString(),mediaType:mediaType))) }
    public func sendImage(_ bytes: Data, mediaType: String = "image/jpeg") async throws { try await send(.image(LiveClientImageEvent(data:bytes.base64EncodedString(),mediaType:mediaType))) }
    public func sendToolResult(id: String, content: [ToolResultContentPart]) async throws { try await send(.toolResult(LiveClientToolResultEvent(id:id,content:content))) }
    public func interrupt() async throws { try await send(.interrupt(LiveClientInterruptEvent())) }
    public func endAudio() async throws { try await send(.endAudio(LiveClientEndAudioEvent())) }
    public func receive() async throws -> LiveServerEvent? {
        guard !receiving else { throw TransportError("live session already has an active receiver") }; receiving = true; defer { receiving = false }
        return try await withTaskCancellationHandler {
            while !closed {
                try Task.checkCancellation(); if !pending.isEmpty { return pending.removeFirst() }
                guard let bytes = try await socket.receive() else { return nil }; pending += try lm.decodeLiveEvent(bytes)
            }; return nil
        } onCancel: { socket.close() }
    }
    public nonisolated func turn() -> TurnView { TurnView(session:self) }
    public func close() { if !closed { closed = true; socket.close(); pending.removeAll() } }
    public struct AsyncIterator: AsyncIteratorProtocol { let session: LiveSession; public mutating func next() async throws -> LiveServerEvent? { try await session.receive() } }
    public nonisolated func makeAsyncIterator() -> AsyncIterator { AsyncIterator(session:self) }
    deinit { socket.close() }
}
public struct Turn: Sendable {
    public let endedBy: String, text: String, audio: Data, audioMediaType: String?, toolCalls: [ToolCallPart], usage: Usage?, error: ErrorDetail?, events: [LiveServerEvent]
    public var ok: Bool { endedBy == "turn_end" }
}
public func sumUsage(_ a: Usage?, _ b: Usage) throws -> Usage {
    guard let a else { return b }; var value: J = [:]
    for field in Tables.schema["Usage"].o.keys { let x = a.rawValue[field], y = b.rawValue[field]; if x.isNumber && y.isNumber { let (sum,overflow) = x.i.addingReportingOverflow(y.i); if overflow { throw ValueError("usage count overflow") }; value[field] = j(sum) } }
    return try Usage(json:value)
}
public func materializeTurn(_ events: [LiveServerEvent]) throws -> Turn {
    var text = "", audio = Data(), mime: String?, calls: [ToolCallPart] = [], usage: Usage?, error: ErrorDetail?
    for event in events { switch event {
    case .text(let e): text += e.text
    case .audio(let e): if let mime, let other = e.mediaType, mime != other { throw ValueError("a turn cannot concatenate different audio media types") }; mime = mime ?? e.mediaType; audio.append(try decodeLiveAudio(e.data))
    case .toolCall(let e): calls.append(try ToolCallPart(id:e.id,name:e.name,input:e.input))
    case .usage(let e): usage = try sumUsage(usage,e.usage)
    case .turnEnd(let e): usage = try sumUsage(usage,e.usage)
    case .error(let e): error = e.error
    default: break
    } }
    let last = events.last?.rawValue["type"].s ?? "", ended = ["turn_end","interrupted","error","tool_call"].contains(last) ? last : "incomplete"
    return Turn(endedBy:ended,text:text,audio:audio,audioMediaType:mime,toolCalls:calls,usage:usage,error:error,events:events)
}
public actor TurnView: AsyncSequence {
    public typealias Element = LiveServerEvent
    let session: LiveSession
    var events: [LiveServerEvent] = [], done = false, reading = false, failure: (any Error)?, resultValue: Turn?
    init(session: LiveSession) { self.session = session }
    public func snapshot() throws -> Turn { try materializeTurn(events) }
    public func next() async throws -> LiveServerEvent? {
        if let failure { throw failure }; if done { return nil }; if reading { throw TransportError("turn view already has an active reader") }; reading = true; defer { reading = false }
        do { guard let event = try await session.receive() else { throw TransportError("live session closed before turn boundary") }; events.append(event); if ["turn_end","interrupted","error"].contains(event.rawValue["type"].s) { done = true }; return event }
        catch { failure = error; throw error }
    }
    public func result() async throws -> Turn {
        if let resultValue { return resultValue }; if let failure { throw failure }
        if events.last?.rawValue["type"] != "tool_call" { while let e = try await next() { if case .toolCall = e { break } } }
        let value = try snapshot(); guard value.endedBy != "incomplete" else { throw TransportError("turn view closed before turn boundary; inspect snapshot") }; done = true; resultValue = value; return value
    }
    public func close() throws { guard !reading else { throw TransportError("stop active turn reader before closing view") }; done = true }
    public struct AsyncIterator: AsyncIteratorProtocol { let view: TurnView; public mutating func next() async throws -> LiveServerEvent? { try await view.next() } }
    public nonisolated func makeAsyncIterator() -> AsyncIterator { AsyncIterator(view:self) }
}
extension ProviderLM {
    public func live(_ config: LiveConfig, connect: LiveConnector = { try await connectLiveSocket($0) }) async throws -> LiveSession {
        let frames = try liveSetupFrames(config), wire = try await emit("GET","realtime",params:dialect == "gemini" ? [:] : ["model":j(config.model)])
        guard var url = URLComponents(string:wire.url) else { throw ValueError("invalid live URL") }; url.scheme = url.scheme == "https" ? "wss" : "ws"; var headers = wire.headers
        if dialect == "gemini" { url.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"; if headers["x-goog-api-key"].isString { url.queryItems = [URLQueryItem(name:"key",value:headers["x-goog-api-key"].s)]; headers = headers.without(["x-goog-api-key"]) } }
        guard let address = url.string else { throw ValueError("invalid live URL") }; let socket = try await connect(TransportRequest(method:"GET",url:address,headers:headers))
        return try await withTaskCancellationHandler {
        do {
            for frame in frames { try await socket.send(frame.jsonData()) }
            if dialect == "gemini" {
                var ready = false
                for _ in 0..<128 { try Task.checkCancellation(); guard let bytes = try await socket.receive() else { throw TransportError("live connection closed during setup") }; guard let d = try? J.parse(bytes), d.isObject else { continue }; if d.has("setupComplete") { ready = true; break }; if d.has("error") { throw InvalidRequestError("live setup failed",metadata:["provider":j(provider),"provider_code":d["error"]["status"]]) } }
                if !ready { throw TransportError("live setup exceeded frame limit") }
            }
            return LiveSession(socket:socket,lm:self,config:config)
        } catch { socket.close(); throw error }
        } onCancel: { socket.close() }
    }
    public func withLiveSession<T: Sendable>(_ config: LiveConfig, connect: LiveConnector = { try await connectLiveSocket($0) }, operation: @Sendable (LiveSession) async throws -> T) async throws -> T {
        let session = try await live(config,connect:connect)
        do { let result = try await operation(session); await session.close(); return result } catch { await session.close(); throw error }
    }
}

private func decodeLiveAudio(_ text: String) throws -> Data { guard let bytes = Data(base64Encoded:try base64Data(text)) else { throw ValueError("invalid base64 audio") }; return bytes }
