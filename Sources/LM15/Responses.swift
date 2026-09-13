import Foundation

extension ProviderLM {
    static let geminiFinishErrors = ["SAFETY","RECITATION","LANGUAGE","BLOCKLIST","PROHIBITED_CONTENT","SPII","MALFORMED_FUNCTION_CALL","IMAGE_SAFETY","IMAGE_PROHIBITED_CONTENT","IMAGE_OTHER","NO_IMAGE","IMAGE_RECITATION","UNEXPECTED_TOOL_CALL","TOO_MANY_TOOL_CALLS","MISSING_THOUGHT_SIGNATURE","MALFORMED_RESPONSE"]
    static let chatFinish = ["stop":"stop","length":"length","tool_calls":"tool_call","function_call":"tool_call","content_filter":"content_filter"]
    func unnamed(_ path: String) throws -> Never { throw ProviderError("\(provider): \(path) is a tool call with no name (MAP-9)",metadata:["provider":j(provider)]) }
    func openaiUsage(_ u: J, chat: Bool = false) throws -> J {
        let ind = u[chat ? "prompt_tokens_details" : "input_tokens_details"], out = u[chat ? "completion_tokens_details" : "output_tokens_details"]
        return try Canonical.normalize("Usage",["input_tokens":u[chat ? "prompt_tokens" : "input_tokens"],"output_tokens":u[chat ? "completion_tokens" : "output_tokens"],"total_tokens":u["total_tokens"],"reasoning_tokens":out["reasoning_tokens"],"cache_read_tokens":ind["cached_tokens"],"cache_write_tokens":ind["cache_write_tokens"],"input_audio_tokens":ind["audio_tokens"],"output_audio_tokens":out["audio_tokens"]])
    }
    func anthropicUsage(_ u: J) throws -> J { try Canonical.normalize("Usage",["input_tokens":u["input_tokens"],"output_tokens":u["output_tokens"],"cache_read_tokens":u["cache_read_input_tokens"],"cache_write_tokens":u["cache_creation_input_tokens"],"reasoning_tokens":u["output_tokens_details"]["thinking_tokens"]]) }
    func geminiUsage(_ u: J) throws -> J {
        if u.empty { return [:] }
        func tokens(_ d: J) -> J { let values = d.a.filter { $0["modality"] == "AUDIO" }.map { $0["tokenCount"].i }; return values.isEmpty ? .null : j(values.reduce(0,+)) }
        return try Canonical.normalize("Usage",["input_tokens":u["promptTokenCount"].or(0),"output_tokens":u["candidatesTokenCount"].or(u["responseTokenCount"].or(0)),"total_tokens":u["totalTokenCount"],"cache_read_tokens":u["cachedContentTokenCount"],"reasoning_tokens":u["thoughtsTokenCount"],"input_audio_tokens":tokens(u["promptTokensDetails"]),"output_audio_tokens":tokens(u["candidatesTokensDetails"].or(u["responseTokensDetails"]))])
    }
    func openaiLogprobs(_ entries: J) throws -> [J] {
        try entries.a.filter { $0.isObject && $0.has("token") && $0.has("logprob") }.map { e in
            let top = try e["top_logprobs"].a.filter { $0.isObject && $0.has("token") && $0.has("logprob") }.map { a in try Canonical.normalize("TopLogprob",["token":j(a["token"].stringValue),"logprob":.number(a["logprob"].d),"bytes":a["bytes"].isArray ? a["bytes"] : .null]) }
            return try Canonical.normalize("TokenLogprob",["token":j(e["token"].stringValue),"logprob":.number(e["logprob"].d),"bytes":e["bytes"].isArray ? e["bytes"] : .null,"top":arr(top)])
        }
    }
    func geminiLogprobs(_ d: J) throws -> [J] {
        try d["chosenCandidates"].a.enumerated().compactMap { i,e in
            guard e.isObject else { return nil }
            let top = try d["topCandidates"][i]["candidates"].a.filter(\.isObject).map { a in try Canonical.normalize("TopLogprob",["token":j(a["token"].or("").stringValue),"logprob":.number(a["logProbability"].d),"token_id":a["tokenId"]]) }
            return try Canonical.normalize("TokenLogprob",["token":j(e["token"].or("").stringValue),"logprob":.number(e["logProbability"].d),"token_id":e["tokenId"],"top":arr(top)])
        }
    }
    func citationPart(_ d: J, source: String? = nil, anthropic: Bool = false) throws -> J? {
        if !d.isObject { return nil }
        let url = nonempty(d["url"]).or(nonempty(d["uri"]))
        let title = (anthropic ? ["title","document_title","source_title"] : ["title","filename","file_id"]).map { nonempty(d[$0]) }.first(where: \.present) ?? .null
        var text = (anthropic ? ["cited_text","text","quote"] : ["text","snippet","cited_text","quote"]).map { nonempty(d[$0]) }.first(where: \.present) ?? .null
        if text.isNull, let source, d["start_index"].isNumber, d["end_index"].isNumber { text = sliceText(source,d["start_index"].i,d["end_index"].i) }
        if url.isNull && title.isNull && text.isNull { return nil }
        return try Canonical.normalize("CitationPart",["url":url.isNull ? .null : j(url.stringValue),"title":title.isNull ? .null : j(title.stringValue),"text":text.isNull ? .null : j(text.stringValue)])
    }
    func finishReason(_ raw: J, tool: Bool = false, data: J = [:], unmapped: inout [J], path: String = "choices[0]") -> J {
        if tool { return "tool_call" }
        switch dialect {
        case "anthropic": if ["max_tokens","model_context_window_exceeded"].contains(raw.s) { return "length" }; if ["tool_use","pause_turn"].contains(raw.s) { return "tool_call" }; if ["refusal","safety","content_filter"].contains(raw.s) { return "content_filter" }
        case "gemini": if raw == "MAX_TOKENS" { return "length" }; if ["SAFETY","RECITATION","BLOCKLIST","PROHIBITED_CONTENT","SPII"].contains(raw.s) { return "content_filter" }
        case "openai-chat": if let finish = Self.chatFinish[raw.s] { return j(finish) }; if nonempty(raw).present { unmapped.append(unmappedEntry(path+".finish_reason",raw)) }
        default: let reason = data["incomplete_details"]["reason"].s.lowercased(); if data["status"] == "incomplete" && reason.contains("token") { return "length" }; if reason.contains("content_filter") || reason.contains("safety") { return "content_filter" }
        }; return "stop"
    }
    func responseError(_ data: J) throws {
        let e = data["error"]; if !e.isObject { return }; let pc = nonempty(e["code"]), code = Self.openaiErrors[pc.s] ?? "server"
        throw errorFromCode(code,e["message"].or(pc.or("provider error")).stringValue,["provider":j(provider),"provider_code":pc])
    }
    public func parseResponse(_ request: Request, response: HTTPResponse) throws -> Response {
        if response.status >= 400 { throw normalizeError(status:response.status,body:String(decoding:response.body,as:UTF8.self),headers:response.headers) }
        let data = try response.json(); guard data.isObject else { throw TypeError("provider response must be an object") }
        switch dialect { case "openai-chat": return try responseFromOpenAIChat(data,model:request.model); case "openai-responses": return try parseResponses(data,request.model); case "anthropic": return try parseAnthropic(data,request.model); default: return try parseGemini(data,request.model) }
    }
    func makeResponse(_ data: J, _ model: String, _ parts: [J], _ usage: J, _ finish: J, _ unmapped: [J], _ logprobs: [J] = [], id: J? = nil) throws -> Response {
        let parts: [J] = parts.isEmpty ? [["type":"text","text":""]] : parts, raw = unmapped.isEmpty ? data : data.with("_lm15_unmapped",arr(unmapped)), responseID = nonempty(id ?? data["id"])
        return try Response(json:["id":responseID.isNull ? .null : j(responseID.stringValue),"model":j(model),"message":["role":"assistant","parts":arr(parts)],"usage":usage,"finish_reason":finish,"provider_data":raw,"logprobs":logprobs.isEmpty ? .null : arr(logprobs)])
    }
    public func responseFromOpenAIChat(_ data: JSONValue, model: String? = nil, choice: Int? = nil) throws -> Response {
        try responseError(data); let choices = data["choices"].or([])
        guard choices.isArray else { throw TypeError("choices must be an array") }
        if choice == nil && choices.a.count > 1 { try unsupported("multiple choices; select a choice index") }
        if let choice, !choices.a.indices.contains(choice) { throw ValueError("choice index out of bounds") }
        let index = choice ?? 0, path = "choices[\(index)]", ch = choices[index], m = ch["message"]; var unmapped: [J] = [], parts: [J] = []
        if !choices.empty && !ch.isObject { unmapped.append(unmappedEntry(path,j(wireType(ch)))) }
        let thought = nonempty(m["reasoning_content"]).or(nonempty(m["reasoning"]))
        if thought.present { parts.append(["type":"thinking","text":j(thought.stringValue)]) }
        let content = m["content"]
        if content.isString { if !content.empty { parts.append(["type":"text","text":content]) } }
        else if content.isArray { for (i,b) in content.a.enumerated() { if b.isObject && b["type"] == "text" { parts.append(["type":"text","text":j(b["text"].or("").stringValue)]) } else { unmapped.append(unmappedEntry("\(path).message.content[\(i)]",b.isObject ? b["type"] : j(wireType(b)))) } } }
        else if content.present { unmapped.append(unmappedEntry(path+".message.content",j(wireType(content)))) }
        if nonempty(m["refusal"]).present { parts.append(["type":"refusal","text":j(m["refusal"].stringValue)]) }
        for (i,b) in m["tool_calls"].a.enumerated() {
            let bpath = "\(path).message.tool_calls[\(i)]"
            if !b.isObject || b["type"].present && b["type"] != "function" { unmapped.append(unmappedEntry(bpath,b.isObject ? b["type"] : j(wireType(b)))); continue }
            let f = b["function"]; if nonempty(f["name"]).isNull { try unnamed(bpath) }
            parts.append(["type":"tool_call","id":j(nonempty(b["id"]).or(j("call_\(parts.count)")).stringValue),"name":j(f["name"].stringValue),"input":parseObject(f["arguments"])])
        }
        let resolvedModel = nonempty(data["model"]).isNull ? model : data["model"].s; guard let resolvedModel else { throw ValueError("response carries no model") }
        let finish = finishReason(ch["finish_reason"],tool:parts.contains { $0["type"] == "tool_call" },unmapped:&unmapped,path:path)
        return try makeResponse(data,resolvedModel,parts,openaiUsage(data["usage"],chat:true),finish,unmapped,openaiLogprobs(ch["logprobs"]["content"]))
    }
    func parseResponses(_ data: J, _ model: String) throws -> Response {
        try responseError(data); var parts: [J] = [], unmapped: [J] = [], logprobs: [J] = []
        for (i,item) in data["output"].a.enumerated() {
            let path = "output[\(i)]"; if !item.isObject { unmapped.append(unmappedEntry(path,j(wireType(item)))); continue }
            switch item["type"].s {
            case "message": for (k,c) in item["content"].a.enumerated() {
                let cpath = "\(path).content[\(k)]"; if !c.isObject { unmapped.append(unmappedEntry(cpath,j(wireType(c)))); continue }
                switch c["type"].s {
                case "output_text","text": let text = c["text"].or("").stringValue; parts.append(["type":"text","text":j(text)]); logprobs += try openaiLogprobs(c["logprobs"]); parts += try c["annotations"].a.compactMap { try citationPart($0,source:text) }
                case "refusal": let text = nonempty(c["refusal"]).or(c["text"].or("")).stringValue; parts.append(["type":text.isEmpty ? "text" : "refusal","text":j(text)])
                case "output_image": let b64 = nonempty(c["b64_json"]).or(nonempty(c["image_base64"])); if b64.present { parts.append(["type":"image","media_type":"image/png","data":j(b64.stringValue)]) }
                case "output_audio": let b64 = nonempty(c["audio"]["data"]).or(nonempty(c["b64_json"])); if b64.present { parts.append(["type":"audio","media_type":"audio/wav","data":j(b64.stringValue)]) }
                default: unmapped.append(unmappedEntry(cpath,c["type"]))
                }
            }
            case "function_call":
                if nonempty(item["name"]).isNull { try unnamed(path) }
                parts.append(["type":"tool_call","id":j(nonempty(item["call_id"]).or(nonempty(item["id"])).or(j("call_\(parts.count)")).stringValue),"name":j(item["name"].stringValue),"input":parseObject(item["arguments"])])
            case "reasoning":
                let summary = item["summary"], text = summary.isArray ? summary.a.map { ($0.isObject ? $0["text"] : $0).stringValue }.joined(separator:"\n") : nonempty(summary).or(item["text"].or("")).stringValue
                let state = J.object(item.o.filter { ["id","encrypted_content"].contains($0.key) && nonempty($0.value).present }.mapValues { j($0.stringValue) })
                if !text.isEmpty || !state.empty { parts.append(["type":"thinking","text":j(text),"continuation":state.empty ? [] : continuation("openai","reasoning_item",state)]) }
            case "web_search_call","file_search_call","code_interpreter_call","computer_call","computer_use_call": break
            default: unmapped.append(unmappedEntry(path,item["type"]))
            }
        }
        if parts.isEmpty { parts = [["type":"text","text":j(data["output_text"].or("").stringValue)]] }
        let finish = finishReason(.null,tool:parts.contains { $0["type"] == "tool_call" },data:data,unmapped:&unmapped)
        return try makeResponse(data,nonempty(data["model"]).or(j(model)).s,parts,openaiUsage(data["usage"]),finish,unmapped,logprobs)
    }
    func parseAnthropic(_ data: J, _ model: String) throws -> Response {
        var parts: [J] = [], unmapped: [J] = []
        for (i,b) in data["content"].a.enumerated() {
            let path = "content[\(i)]"; if !b.isObject { unmapped.append(unmappedEntry(path,j(wireType(b)))); continue }
            switch b["type"].s {
            case "text": parts.append(["type":"text","text":j(b["text"].or("").stringValue)]); parts += try b["citations"].a.compactMap { try citationPart($0,anthropic:true) }
            case "tool_use": if nonempty(b["name"]).isNull { try unnamed(path) }; parts.append(["type":"tool_call","id":j(nonempty(b["id"]).or(j("tool_\(parts.count)")).stringValue),"name":j(b["name"].stringValue),"input":b["input"].isObject ? b["input"] : [:]])
            case "thinking": let state: J = nonempty(b["signature"]).present ? continuation("anthropic","thinking_signature",["signature":j(b["signature"].stringValue)]) : []; parts.append(["type":"thinking","text":j(nonempty(b["thinking"]).or(b["text"].or("")).stringValue),"continuation":state])
            case "redacted_thinking": parts.append(["type":"thinking","text":"","continuation":b["data"].isNull ? [] : continuation("anthropic","redacted_thinking",["data":b["data"]])])
            case "server_tool_use","web_search_tool_result","code_execution_tool_result": break
            default: unmapped.append(unmappedEntry(path,b["type"]))
            }
        }
        let finish = finishReason(data["stop_reason"],tool:parts.contains { $0["type"] == "tool_call" },unmapped:&unmapped)
        return try makeResponse(data,nonempty(data["model"]).or(j(model)).s,parts,anthropicUsage(data["usage"]),finish,unmapped)
    }
    func geminiInbandError(_ data: J) -> LM15Error? {
        let block = data["promptFeedback"]["blockReason"]
        if nonempty(block).present && block != "BLOCK_REASON_UNSPECIFIED" { return InvalidRequestError("Prompt blocked: \(block.s)",metadata:["provider":j(provider),"provider_code":"promptFeedback"]) }
        let c = data["candidates"][0]
        if Self.geminiFinishErrors.contains(c["finishReason"].s) { return InvalidRequestError(nonempty(c["finishMessage"]).or(j("Candidate blocked: \(c["finishReason"].s)")).s,metadata:["provider":j(provider),"provider_code":c["finishReason"]]) }; return nil
    }
    func geminiCitations(_ candidate: J, _ fullText: String) throws -> [J] {
        let g = candidate["groundingMetadata"], chunks = g["groundingChunks"]; var out: [J] = []
        for support in g["groundingSupports"].a where support.isObject {
            let s = support["segment"]; var text = nonempty(s["text"])
            if text.isNull && s["startIndex"].isNumber && s["endIndex"].isNumber { text = sliceText(fullText,s["startIndex"].i,s["endIndex"].i) }
            for i in support["groundingChunkIndices"].a {
                let c = i.isNumber && i.i >= 0 ? chunks[i.i] : .null, source = c["web"].or(c["retrievedContext"]).or(c["googleSearch"])
                let url = nonempty(source["uri"]).or(nonempty(source["url"])), title = nonempty(source["title"]).or(nonempty(source["name"]))
                if url.isNull && title.isNull && text.isNull { continue }
                let p = try Canonical.normalize("CitationPart",["url":url.isNull ? .null : j(url.stringValue),"title":title.isNull ? .null : j(title.stringValue),"text":text]); if !out.contains(p) { out.append(p) }
            }
        }; return out
    }
    func geminiParts(_ blocks: J, unmapped: inout [J], pathPrefix: String = "parts") throws -> [J] {
        var parts: [J] = []
        for (i,b) in blocks.a.enumerated() {
            let path = "\(pathPrefix)[\(i)]"; if !b.isObject { unmapped.append(unmappedEntry(path,j(wireType(b)))); continue }
            var state: J = b["thoughtSignature"].isNull ? [] : continuation("gemini","thought_signature",["value":j(b["thoughtSignature"].stringValue)])
            if b.has("text") { parts.append(["type":b["thought"].b ? "thinking" : "text","text":j(b["text"].or("").stringValue),"continuation":state]) }
            else if b["functionCall"].isObject {
                let fc = b["functionCall"]; if nonempty(fc["name"]).isNull { try unnamed(path) }; let sig = b["thoughtSignature"].or(fc["thoughtSignature"]); state = sig.isNull ? [] : continuation("gemini","thought_signature",["value":j(sig.stringValue)])
                parts.append(["type":"tool_call","id":j(nonempty(fc["id"]).or(j("tool_call_\(parts.count)")).stringValue),"name":j(fc["name"].stringValue),"input":fc["args"].isObject ? fc["args"] : [:],"continuation":state])
            } else if b["inlineData"].isObject || b["fileData"].isObject {
                let inline = b["inlineData"].isObject, d = b[inline ? "inlineData" : "fileData"], source = nonempty(d[inline ? "data" : "fileUri"]); if source.isNull { continue }
                let mime = nonempty(d["mimeType"]).or("application/octet-stream"); parts.append(.object(["type":mime.s.hasPrefix("image/") ? "image" : mime.s.hasPrefix("audio/") ? "audio" : "document","media_type":mime,inline ? "data" : "url":j(source.stringValue)]))
            } else if b.has("executableCode") || b.has("codeExecutionResult") { continue }
            else { unmapped.append(unmappedEntry(path,j(b.empty ? "<empty>" : b.o.keys.sorted().joined(separator:"+")))) }
        }; return parts
    }
    func parseGemini(_ data: J, _ model: String) throws -> Response {
        if let error = geminiInbandError(data) { throw error }; let candidate = data["candidates"][0]; var unmapped: [J] = []
        var parts = try geminiParts(candidate["content"]["parts"],unmapped:&unmapped,pathPrefix:"candidates[0].content.parts")
        parts += try geminiCitations(candidate,parts.filter { $0["type"] == "text" }.map { $0["text"].s }.joined())
        let finish = finishReason(candidate["finishReason"],tool:parts.contains { $0["type"] == "tool_call" },unmapped:&unmapped)
        return try makeResponse(data,model,parts,geminiUsage(data["usageMetadata"]),finish,unmapped,geminiLogprobs(candidate["logprobsResult"]),id:data["responseId"])
    }
}
func nonempty(_ v: J) -> J { v.isNull || v == false || v == "" ? .null : v }
func wireType(_ v: J) -> String { switch v { case .null:return "NoneType"; case .bool:return "bool"; case .int:return "int"; case .number:return "float"; case .string:return "str"; case .array:return "list"; case .object,.orderedObject:return "dict" } }
func unmappedEntry(_ path: String, _ type: J) -> J { ["path":j(path),"type":nonempty(type).isNull ? "<missing>" : j(type.stringValue)] }
func continuation(_ provider: String, _ kind: String, _ data: J) -> J { [["provider":j(provider),"kind":j(kind),"data":data]] }
func sliceText(_ text: String, _ start: Int, _ end: Int) -> J { let scalars = Array(text.unicodeScalars); guard start >= 0, start < end, end <= scalars.count else { return .null }; return j(String(String.UnicodeScalarView(scalars[start..<end]))) }

public func responseFromOpenAIChat(_ body: JSONValue, model: String? = nil, choice: Int? = nil) throws -> Response { try OpenAIChatLM(env:[:]).responseFromOpenAIChat(body,model:model,choice:choice) }
