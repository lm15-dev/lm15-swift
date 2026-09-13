import Foundation

extension ProviderLM {
    func delta(_ type: String, _ fields: J) -> J { ["type":"delta","delta":fields.with("type",j(type))] }
    func streamError(_ payload: J, _ preferred: String) -> J {
        let e = payload["error"], pc = nonempty(e[preferred]).or(nonempty(e["code"])).or(nonempty(e["type"])).or(nonempty(payload["code"])).or(nonempty(payload["error_type"])).or("provider")
        return ["type":"error","error":errorDetail(pc,nonempty(e["message"]).or(payload["message"].or("")).stringValue)]
    }
    func parseStreamEvents(_ request: Request, _ event: SSEEvent) throws -> [J] {
        if event.data.isEmpty { return [] }; if event.data == "[DONE]" { return [["type":"end"]] }
        let data = try J.parse(event.data); if !data.isObject { return [] }
        switch dialect { case "openai-chat": return try chatStreamEvents(data); case "openai-responses": return try responsesStreamEvents(request,data); case "anthropic": return try anthropicStreamEvents(request,data); default: return try geminiStreamEvents(data) }
    }
    func chatStreamEvents(_ p: J) throws -> [J] {
        if p["error"].isObject { return [streamError(p,"code")] }; let ch = p["choices"][0], d = ch["delta"]; var out: [J] = []
        let thought = nonempty(d["reasoning_content"]).or(nonempty(d["reasoning"])); if thought.present { out.append(delta("thinking",["text":j(thought.stringValue)])) }
        if d["content"].isString && !d["content"].empty { out.append(delta("text",["text":d["content"],"logprobs":arr(try openaiLogprobs(ch["logprobs"]["content"]))])) }
        for c in d["tool_calls"].a where c.isObject { let f = c["function"]; out.append(delta("tool_call",["input":j(f["arguments"].or("").stringValue),"part_index":c["index"].or(0),"id":nonempty(c["id"]),"name":nonempty(f["name"])])) }
        if nonempty(ch["finish_reason"]).present { out.append(["type":"end","finish_reason":j(Self.chatFinish[ch["finish_reason"].s] ?? "stop"),"usage":p["usage"].isObject ? try openaiUsage(p["usage"],chat:true) : .null,"provider_data":p]) }
        else if p["usage"].isObject { out.append(["type":"end","usage":try openaiUsage(p["usage"],chat:true),"provider_data":p]) }; return out
    }
    func responsesStreamEvents(_ request: Request, _ p: J) throws -> [J] {
        let type = p["type"].s, idx = p["output_index"].or(0), item = p["item"]
        if ["response.output_item.added","response.output_item.done"].contains(type) && item["type"] == "reasoning" {
            if type == "response.output_item.added" { return [delta("thinking",["text":"","part_index":idx])] }
            let state = J.object(item.o.filter { ["id","encrypted_content"].contains($0.key) && nonempty($0.value).present })
            return state.empty ? [] : [delta("continuation",["provider":"openai","kind":"reasoning_item","data":state,"part_index":idx])]
        }
        switch type {
        case "response.created": let r = p["response"]; return [["type":"start","id":nonempty(r["id"]),"model":nonempty(r["model"]).or(j(request.model))]]
        case "response.output_text.delta","response.refusal.delta": return [delta("text",["text":j(p["delta"].or("").stringValue),"part_index":idx,"logprobs":arr(try openaiLogprobs(p["logprobs"]))])]
        case "response.reasoning_summary_text.delta","response.reasoning_text.delta": return [delta("thinking",["text":j(p["delta"].or("").stringValue),"part_index":idx])]
        case "response.output_text.annotation.added": if let c = try citationPart(p["annotation"]) { return [delta("citation",c.with("part_index",idx))] }; return []
        case "response.output_audio.delta": return [delta("audio",["data":j(p["delta"].or("").stringValue),"part_index":idx,"media_type":"audio/wav"])]
        case "response.output_image.delta","response.image.delta": return [delta("image",["data":j(p["delta"].or("").stringValue),"part_index":idx,"media_type":"image/png"])]
        case "response.output_item.added": return item["type"] == "function_call" ? [delta("tool_call",["input":j(item["arguments"].or("").stringValue),"part_index":idx,"id":nonempty(item["call_id"]).or(nonempty(item["id"])),"name":nonempty(item["name"])])] : []
        case "response.function_call_arguments.delta": return [delta("tool_call",["input":j(p["delta"].or("").stringValue),"part_index":idx,"id":nonempty(p["call_id"]).or(nonempty(p["id"])),"name":nonempty(p["name"])])]
        case "response.completed": let r = p["response"], tool = r["output"].a.contains { $0["type"] == "function_call" }; return [["type":"end","finish_reason":tool ? "tool_call" : "stop","usage":try openaiUsage(r["usage"]),"provider_data":r]]
        case "response.error","error": return [streamError(p,"code")]
        default: return []
        }
    }
    func anthropicStreamEvents(_ request: Request, _ p: J) throws -> [J] {
        let idx = p["index"].or(0)
        switch p["type"].s {
        case "message_start": let m = p["message"]; return [["type":"start","id":nonempty(m["id"]),"model":nonempty(m["model"]).or(j(request.model))]]
        case "content_block_start":
            let b = p["content_block"]
            if b["type"] == "tool_use" { let input = b["input"].isObject ? (b["input"].empty ? "" : try b["input"].jsonString(sortedKeys:false)) : b["input"].or("").stringValue; return [delta("tool_call",["input":j(input),"part_index":idx,"id":nonempty(b["id"]),"name":nonempty(b["name"])])] }
            if b["type"] == "redacted_thinking" && b["data"].present { return [delta("thinking",["text":"","part_index":idx]),delta("continuation",["provider":"anthropic","kind":"redacted_thinking","data":["data":b["data"]],"part_index":idx])] }; return []
        case "content_block_delta":
            let d = p["delta"]
            switch d["type"].s {
            case "text_delta": return [delta("text",["text":j(d["text"].or("").stringValue),"part_index":idx])]
            case "input_json_delta": return [delta("tool_call",["input":j(d["partial_json"].or("").stringValue),"part_index":idx])]
            case "thinking_delta": return [delta("thinking",["text":j(d["thinking"].or("").stringValue),"part_index":idx])]
            case "signature_delta": return nonempty(d["signature"]).present ? [delta("continuation",["provider":"anthropic","kind":"thinking_signature","data":["signature":j(d["signature"].stringValue)],"part_index":idx])] : []
            case "citation_delta","citations_delta": let c = d["citation"].isObject ? d["citation"] : d; return [delta("citation",["text":nonempty(c["cited_text"]).or(nonempty(c["text"])),"url":nonempty(c["url"]),"title":nonempty(c["title"]),"part_index":idx])]
            default: return []
            }
        case "message_delta":
            let reason = p["delta"]["stop_reason"], usage: J = p["usage"].empty ? .null : try anthropicUsage(p["usage"]); var unmapped: [J] = []
            return reason.present || usage.present ? [["type":"end","finish_reason":reason.present ? finishReason(reason,unmapped:&unmapped) : .null,"usage":usage,"provider_data":p]] : []
        case "message_stop": return [["type":"end"]]
        case "error": return [streamError(p,"type")]
        default: return []
        }
    }
    func geminiStreamEvents(_ p: J) throws -> [J] {
        if p.has("error") { return [streamError(p,"status")] }
        if let e = geminiInbandError(p) { return [["type":"error","error":["code":j(e.code),"provider_code":"inband_finish_reason","message":j(e.message)]]] }
        let c = p["candidates"][0]; var logs = try geminiLogprobs(c["logprobsResult"]), out: [J] = [], tool = false
        for (i,b) in c["content"]["parts"].a.enumerated() where b.isObject {
            if b.has("text") {
                var attrs: J = ["text":j(b["text"].or("").stringValue),"part_index":j(i)]; if !b["thought"].b { attrs["logprobs"] = arr(logs); logs = [] }
                out.append(delta(b["thought"].b ? "thinking" : "text",attrs))
                if b["thoughtSignature"].present { out.append(delta("continuation",["provider":"gemini","kind":"thought_signature","data":["value":j(b["thoughtSignature"].stringValue)],"part_index":j(i)])) }
            } else if b["functionCall"].isObject {
                let fc = b["functionCall"]; tool = true
                out.append(delta("tool_call",["input":j(try fc["args"].or([:]).jsonString(sortedKeys:false)),"part_index":j(i),"id":nonempty(fc["id"]),"name":nonempty(fc["name"])]))
                let sig = b["thoughtSignature"].or(fc["thoughtSignature"]); if sig.present { out.append(delta("continuation",["provider":"gemini","kind":"thought_signature","data":["value":j(sig.stringValue)],"part_index":j(i)])) }
            } else if b["inlineData"].isObject {
                let d = b["inlineData"], mime = d["mimeType"].or("application/octet-stream")
                if mime.s.hasPrefix("audio/") || mime.s.hasPrefix("image/") { out.append(delta(mime.s.hasPrefix("audio/") ? "audio" : "image",["data":j(d["data"].or("").stringValue),"part_index":j(i),"media_type":mime])) }
            }
        }
        var unmapped: [J] = []
        if nonempty(c["finishReason"]).present { out.append(["type":"end","finish_reason":finishReason(c["finishReason"],tool:tool,unmapped:&unmapped),"usage":try geminiUsage(p["usageMetadata"]),"provider_data":p]) }
        else if out.isEmpty && p.has("usageMetadata") { out.append(["type":"end","finish_reason":"stop","usage":try geminiUsage(p["usageMetadata"]),"provider_data":p]) }; return out
    }
    public func replayStream(_ request: Request, body: Data) throws -> [StreamEvent] {
        var parser = SSEParser(), coalescer = StreamCoalescer(model:request.model), events: [J] = []
        let frames = try parser.feed(body)+parser.finish()
        for frame in frames { for e in try parseStreamEvents(request,frame) { events += coalescer.push(e) } }
        events += coalescer.finishEvents(); return try events.map { try StreamEvent(json:$0) }
    }
    public func complete(_ request: Request) async throws -> Response {
        if provider == "openai-codex" { return try await responseStream(request).response() }
        let wire = try await buildRequest(request); return try parseResponse(request,response:await transport.send(wire))
    }
    public func stream(_ request: Request) -> AsyncThrowingStream<StreamEvent, any Error> { eventSource(request,control:TaskControl()) }
    private func eventSource(_ request: Request, control: TaskControl) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream(bufferingPolicy:.bufferingOldest(256)) { continuation in
            let task = Task {
                do {
                    let wire = try await buildRequest(request,stream:true), source = try await transport.stream(wire)
                    defer { source.cancel() }
                    if source.response.status >= 400 {
                        var body = Data(); for try await chunk in source.chunks { body.append(chunk); if body.count > 1_048_576 { break } }
                        throw normalizeError(status:source.response.status,body:String(decoding:body,as:UTF8.self),headers:source.response.headers)
                    }
                    var parser = SSEParser(), coalescer = StreamCoalescer(model:request.model)
                    func emit(_ events: [J]) throws { for e in events { try Task.checkCancellation(); if case .dropped = continuation.yield(try StreamEvent(json:e)) { throw TransportError("stream consumer exceeded the event buffer") } } }
                    var terminal = false
                    for try await chunk in source.chunks {
                        try Task.checkCancellation()
                        for frame in try parser.feed(chunk) {
                            for e in try parseStreamEvents(request,frame) { try emit(coalescer.push(e)) }
                            if frame.data == "[DONE]" { terminal = true }
                        }
                        if terminal { break }
                    }
                    if !terminal { for frame in try parser.finish() { for e in try parseStreamEvents(request,frame) { try emit(coalescer.push(e)) } } }
                    try emit(coalescer.finishEvents()); continuation.finish()
                } catch { continuation.finish(throwing:error) }
            }
            control.install(task)
            continuation.onTermination = { _ in control.cancel() }
        }
    }
    public func responseStream(_ request: Request) -> ResponseStream { let control = TaskControl(); return ResponseStream(events:eventSource(request,control:control),request:request,cancel:{ control.cancel() }) }
}

final class TaskControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void,Never>?, cancelled = false
    func install(_ task: Task<Void,Never>) { lock.lock(); self.task = task; let stop = cancelled; lock.unlock(); if stop { task.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let current = task; task = nil; lock.unlock(); current?.cancel() }
}
