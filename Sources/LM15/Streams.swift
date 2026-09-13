import Foundation

public struct SSEEvent: Sendable, Equatable { public let data: String; public let event: String? }
public struct SSEParser: Sendable {
    public let maxLineBytes: Int, maxEventBytes: Int
    private var skipLF = false
    private var line = Data(), fields: [String] = [], eventName: String?, size = 0
    public init(maxLineBytes: Int = 65_536, maxEventBytes: Int = 1_048_576) { self.maxLineBytes = maxLineBytes; self.maxEventBytes = maxEventBytes }
    public mutating func feed(_ data: Data) throws -> [SSEEvent] {
        var out: [SSEEvent] = []
        for byte in data {
            if skipLF { skipLF = false; if byte == 10 { continue } }
            line.append(byte); if line.count > maxLineBytes { throw TransportError("SSE line exceeds limit") }
            if byte == 10 || byte == 13 { if let event = try consumeLine() { out.append(event) }; skipLF = byte == 13 }
        }; return out
    }
    public mutating func finish() throws -> [SSEEvent] {
        var out: [SSEEvent] = []; if !line.isEmpty, let e = try consumeLine() { out.append(e) }
        if !fields.isEmpty { out.append(SSEEvent(data:fields.joined(separator:"\n"),event:eventName)); fields = []; eventName = nil; size = 0 }; return out
    }
    private mutating func consumeLine() throws -> SSEEvent? {
        size += line.count; if size > maxEventBytes { throw TransportError("SSE event exceeds limit") }
        while line.last == 10 || line.last == 13 { line.removeLast() }
        let text = String(decoding:line,as:UTF8.self); line.removeAll(keepingCapacity:true)
        if text.isEmpty { let e = fields.isEmpty ? nil : SSEEvent(data:fields.joined(separator:"\n"),event:eventName); fields = []; eventName = nil; size = 0; return e }
        if text.hasPrefix("event:") { eventName = String(text.dropFirst(6)).trimmingCharacters(in:.whitespaces) }
        if text.hasPrefix("data:") { var value = String(text.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }; fields.append(value) }; return nil
    }
}
struct StreamCoalescer {
    let model: String
    var started = false, ended = false, finish: J = .null, usage: J = .null, data: J = .null, rank = -1
    mutating func push(_ e: J) -> [J] {
        switch e["type"].s {
        case "start": if started { return [] }; started = true; return [e]
        case "end":
            ended = true; if e["finish_reason"].present { finish = e["finish_reason"] }; if e["usage"].present { usage = e["usage"] }
            if e["provider_data"].present { let r = e["usage"].present ? 2 : e["finish_reason"].present ? 1 : 0; if r >= rank { data = e["provider_data"]; rank = r } }; return []
        default:
            if !started && e["type"] == "delta" { started = true; return [["type":"start","model":j(model)],e] }; return [e]
        }
    }
    mutating func finishEvents() -> [J] {
        if !ended { return [] }; var out: [J] = []; if !started { out.append(["type":"start","model":j(model)]) }
        out.append(["type":"end","finish_reason":finish,"usage":usage,"provider_data":data]); return out
    }
}
public struct StreamAccumulator: Sendable {
    public let request: Request
    private var parts: [Int:J] = [:], continuationStates: [J] = [], logprobs: [J] = []
    private var id: J = .null, model: J = .null, finish: J = .null, usage: J = .null, providerData: J = .null
    public init(request: Request) { self.request = request }
    public mutating func push(_ event: StreamEvent) throws {
        let e = event.rawValue
        switch e["type"].s {
        case "start": if e["id"].present { id = e["id"] }; if e["model"].present { model = e["model"] }
        case "end": if e["finish_reason"].present { finish = e["finish_reason"] }; if e["usage"].present { usage = e["usage"] }; if e["provider_data"].present { providerData = e["provider_data"] }
        case "delta":
            let d = e["delta"], i = d["part_index"].i
            if d["type"] == "continuation" && d["part_index"].isNull { continuationStates.append(d.without(["type","part_index"])); return }
            var b = parts[i] ?? [:]
            switch d["type"].s {
            case "text","thinking": b[d["type"].s] = j(b[d["type"].s].s+d["text"].s); if d["type"] == "text" { logprobs += d["logprobs"].a }
            case "tool_call": if d["id"].present { b["tool_call"]["id"] = d["id"] }; if d["name"].present { b["tool_call"]["name"] = d["name"] }; b["tool_call"]["raw"] = j(b["tool_call"]["raw"].s+d["input"].s)
            case "audio": b["audio"] = arr(b["audio"].a+[d["data"].or("")]); if !b.has("audio_type") { b["audio_type"] = d["media_type"] }
            case "image":
                var attributes: J = ["type":"image","media_type":d["media_type"].or("image/png")]
                for k in ["data","url","file_id"] where d[k].present { attributes[k] = d[k] }
                if attributes.o.count > 2 { b["image"] = try Canonical.normalize("ImagePart",attributes) }
            case "citation": b["citation"] = arr(b["citation"].a+[try Canonical.normalize("CitationPart",d.without(["type","part_index"]))])
            case "continuation": b["continuation"] = arr(b["continuation"].a+[d.without(["type","part_index"])])
            default: break
            }; parts[i] = b
        default: break
        }
    }
    public func response() throws -> Response {
        let unnamed = parts.keys.sorted().filter { parts[$0]!["tool_call"].present && parts[$0]!["tool_call"]["name"].isNull }
        if let index = unnamed.first { throw StreamAssemblyError("tool call at part \(index) arrived without a name (MAP-9)",metadata:["part_index":j(index),"partial_response":try assemble(skipping:unnamed).toJSON()]) }
        return try assemble(skipping:[])
    }
    public func partial() throws -> Response { do { return try response() } catch let e as StreamAssemblyError { return try Response(json:e.metadata["partial_response"]) } }
    private func assemble(skipping: [Int]) throws -> Response {
        var output: [J] = []
        for i in parts.keys.sorted() {
            let b = parts[i]!, c = b["continuation"].or([]), start = output.count
            for kind in ["thinking","text"] where b[kind].present { output.append(["type":j(kind),"text":b[kind],"continuation":c]) }
            if b["image"].present { output.append(b["image"].with("continuation",c)) }
            if b["audio"].present {
                var bytes = Data()
                for chunk in b["audio"].a where !chunk.empty { let padded = chunk.s + String(repeating:"=",count:(4-chunk.s.utf8.count%4)%4); if let data = Data(base64Encoded:padded) { bytes.append(data) } }
                var mime = b["audio_type"]; if mime.isNull || ["audio/pcm","audio/pcm16"].contains(mime.s) { bytes = pcmToWAV(bytes); mime = "audio/wav" }
                output.append(["type":"audio","media_type":mime,"data":j(bytes.base64EncodedString()),"continuation":c])
            }
            output += b["citation"].a.map { $0.with("continuation",c) }
            if b["tool_call"].present && !skipping.contains(i) { let t = b["tool_call"]; output.append(["type":"tool_call","id":t["id"].or(j("tool_call_\(i)")),"name":t["name"],"input":parseObject(t["raw"]),"continuation":c]) }
            else if output.count == start && !skipping.contains(i) { output.append(["type":"text","text":"","continuation":c]) }
        }
        if output.isEmpty { output.append(["type":"text","text":""]) }
        let tool = output.contains { $0["type"] == "tool_call" }; var reason = finish.or(tool ? "tool_call" : "stop"); if reason == "stop" && tool { reason = "tool_call" }
        return try Response(json:["id":id,"model":model.or(j(request.model)),"message":["role":"assistant","parts":arr(output),"continuation":arr(continuationStates)],"finish_reason":reason,"usage":usage.or([:]),"provider_data":providerData,"logprobs":logprobs.isEmpty ? .null : arr(logprobs)])
    }
}
public func pcmToWAV(_ bytes: Data, sampleRate: Int = 24_000, channels: Int = 1, bits: Int = 16) -> Data {
    var d = Data("RIFF".utf8)
    func word(_ value: Int, _ count: Int) { for i in 0..<count { d.append(UInt8(truncatingIfNeeded:value >> (i*8))) } }
    word(36+bytes.count,4); d.append(Data("WAVEfmt ".utf8)); word(16,4); word(1,2); word(channels,2); word(sampleRate,4); word(sampleRate*channels*bits/8,4); word(channels*bits/8,2); word(bits,2); d.append(Data("data".utf8)); word(bytes.count,4); d.append(bytes); return d
}
public func materializeResponse(_ events: [StreamEvent], request: Request) throws -> Response {
    var accumulator = StreamAccumulator(request:request), ended = false
    for e in events {
        if ended { throw StreamAssemblyError("event after stream end",metadata:["partial_response":try accumulator.partial().toJSON()]) }
        if case .error(let error) = e { throw errorFromCode(error.error.code.rawValue,error.error.message,["provider_code":error.error.rawValue["provider_code"]]) }
        try accumulator.push(e); if case .end = e { ended = true }
    }
    if !ended { throw StreamAssemblyError("stream ended without an end event (MAP-3)",metadata:["partial_response":try accumulator.partial().toJSON()]) }; return try accumulator.response()
}
/// A single-consumer async sequence of text chunks with a canonical event view and assembled result.
public final class ResponseStream: AsyncSequence, Sendable {
    public typealias Element = String
    let state: ResponseStreamState
    let cancelSource: @Sendable () -> Void
    deinit { cancelSource() }
    public init(events: AsyncThrowingStream<StreamEvent, any Error>, request: Request, cancel: @escaping @Sendable () -> Void = {}) { state = ResponseStreamState(events,request,cancel); cancelSource = cancel }
    public struct AsyncIterator: AsyncIteratorProtocol {
        let state: ResponseStreamState
        public mutating func next() async throws -> String? { while let e = try await state.next() { if case .delta(let event) = e, case .text(let delta) = event.delta { return delta.text } }; return nil }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(state:state) }
    public struct Events: AsyncSequence, Sendable {
        public typealias Element = StreamEvent
        let state: ResponseStreamState
        public struct AsyncIterator: AsyncIteratorProtocol { let state: ResponseStreamState; public mutating func next() async throws -> StreamEvent? { try await state.next() } }
        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(state:state) }
    }
    public var events: Events { Events(state:state) }
    public func response() async throws -> Response { try await state.response() }
    public func close() async { await state.close() }
    public var cleanupErrors: [String] { get async { await state.cleanupErrors } }
}
actor ResponseStreamState {
    var iterator: AsyncThrowingStream<StreamEvent, any Error>.Iterator?
    var accumulator: StreamAccumulator, result: Response?, failure: (any Error)?, done = false, reading = false
    var cleanupErrors: [String] = []
    let cancel: @Sendable () -> Void
    init(_ stream: AsyncThrowingStream<StreamEvent, any Error>, _ request: Request, _ cancel: @escaping @Sendable () -> Void) { iterator = stream.makeAsyncIterator(); accumulator = StreamAccumulator(request:request); self.cancel = cancel }
    func next() async throws -> StreamEvent? {
        if let failure { throw failure }; if done { return nil }; if reading { throw TypeError("ResponseStream already has an active reader") }
        reading = true; defer { reading = false }
        var cursor = iterator!; iterator = nil; defer { iterator = cursor }
        do {
            let e: StreamEvent?
            do { e = try await cursor.next(isolation:self) }
            catch { if result != nil { cleanupErrors.append(String(describing:error)); done = true; return nil }; throw error }
            if done { if let failure { throw failure }; return nil }
            guard let e else { done = true; if result == nil { throw StreamAssemblyError("stream ended without end event",metadata:["partial_response":try accumulator.partial().toJSON()]) }; return nil }
            if let result { throw StreamAssemblyError("event after stream end",metadata:["partial_response":result.toJSON()]) }
            if case .error(let event) = e { throw errorFromCode(event.error.code.rawValue,event.error.message,["provider_code":event.error.rawValue["provider_code"]]) }
            try accumulator.push(e); if case .end = e { result = try accumulator.response() }; return e
        } catch { failure = error; cancel(); throw error }
    }
    func response() async throws -> Response { while try await next() != nil {} ; guard let result else { throw StreamAssemblyError("stream has no result") }; return result }
    func close() { if done { return }; done = true; cancel(); if result == nil { failure = StreamAssemblyError("stream closed before end event",metadata:["partial_response":(try? accumulator.partial().toJSON()) ?? .null]) } }
}
