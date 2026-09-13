import Foundation

extension ProviderLM {
    public func buildRequest(_ request: Request, stream: Bool = false) async throws -> TransportRequest {
        try support(stream ? "stream" : "complete")
        let r = request.rawValue; var headers: J = [:], params: J = [:]; let payload: J, path: String
        switch dialect {
        case "openai-chat": payload = try chatPayload(r,stream); path = "chat/completions"
        case "openai-responses": payload = try responsesPayload(r,stream); path = "responses"
        case "anthropic": headers["anthropic-version"] = "2023-06-01"; if r["tools"].a.contains(where: { $0["type"] == "builtin" && $0["name"] == "code_execution" }) { headers["anthropic-beta"] = "code-execution-2025-05-22" }; payload = try anthropicPayload(r,stream); path = "messages"
        default:
            if stream { params["alt"] = "sse" }; var model = pathID(r["model"].s,resource:true).replacingOccurrences(of:"%3A",with:":").replacingOccurrences(of:"%40",with:"@"); if !model.hasPrefix("models/") { model = "models/"+model }; payload = try geminiPayload(r); path = model + (stream ? ":streamGenerateContent" : ":generateContent")
        }
        return try await emit("POST",path,payload:payload,params:params,headers:headers,request:r)
    }
    func systemText(_ r: J) throws -> String { r["system"].isString ? r["system"].s : try partsText(r["system"].a) }
    func checkToolMedia(_ p: J, _ policy: J) throws {
        let admits = ["native":["image","document"],"images":["image"],"reject":[]][policy.s] ?? []
        for c in p["content"].a where Canonical.media.contains(c["type"].s) && !admits.contains(c["type"].s) { try unsupported("\(c["type"].s) in tool results") }
    }
    func toolOutput(_ p: J, _ policy: J, textType: String = "input_text", convert: (J) throws -> J) throws -> J {
        try checkToolMedia(p,policy)
        if !p["content"].a.contains(where: { Canonical.media.contains($0["type"].s) }) { return j((p["is_error"].b ? "[error] " : "") + (try partsText(p["content"].a))) }
        var blocks = try p["content"].a.map(convert)
        if p["is_error"].b { if let i = blocks.firstIndex(where: { $0["type"].s == textType }) { blocks[i]["text"] = j("[error] " + blocks[i]["text"].s) } else { blocks.insert(["type":j(textType),"text":"[error]"],at:0) } }; return arr(blocks)
    }
    /// -1 denotes the system prefix; nil means no explicit breakpoint.
    func cacheMark(_ r: J) -> Int? { let c = r["config"]["cache"]; if c.isNull || c["mode"] == "off" { return nil }; if c["prefix_until_index"].present { return min(c["prefix_until_index"].i,r["messages"].a.count-1) }; return c["prefix"] == "stable" && r["system"].present ? -1 : nil }
    func openaiCache(_ p: inout J, _ r: J, _ policy: J) throws {
        let c = r["config"]["cache"]; if c.isNull { return }; if c["resource"].present { try unsupported("cache resources") }
        if !["openai","openai_implicit"].contains(policy.s) { return }
        let explicit = r["model"].s.range(of:#"^gpt-([6-9]|5\.(?:[6-9]|\d{2,}))"#,options:.regularExpression) != nil
        if c["mode"] == "off" { if policy == "openai" && explicit { p["prompt_cache_options"] = ["mode":"explicit"] }; return }
        if c["key"].present { p["prompt_cache_key"] = c["key"] }; if c["retention"] == "long" { p["prompt_cache_retention"] = "24h" }
        if policy == "openai" && explicit && cacheMark(r) != nil { p["prompt_cache_options"] = ["mode":"explicit"] }
    }
    func openaiInput(_ p: J) throws -> J {
        switch p["type"].s {
        case "text","thinking","citation": return ["type":"input_text","text":j(try partsText([p]))]
        case "image":
            if p["file_id"].present { return ["type":"input_image","file_id":p["file_id"]] }
            var out: J = ["type":"input_image","image_url":p["url"].present ? p["url"] : j(try mediaURI(p))]; if p["detail"].present { out["detail"] = p["detail"] }; return out
        case "audio":
            if p["url"].present { return ["type":"input_audio","audio_url":p["url"]] }; if p["file_id"].present { return ["type":"input_audio","file_id":p["file_id"]] }
            let f = p["media_type"].s.components(separatedBy:"/").last!; return ["type":"input_audio","audio":j(try mediaBase64(p)),"format":j(["mpeg","mp3"].contains(f) ? "mp3" : f)]
        case "document","binary":
            if p["url"].present { return ["type":"input_file","file_url":p["url"]] }; if p["file_id"].present { return ["type":"input_file","file_id":p["file_id"]] }
            return ["type":"input_file","filename":j("file."+p["media_type"].s.components(separatedBy:"/").last!.components(separatedBy:"+")[0]),"file_data":j(try mediaURI(p))]
        case "video": return J.object(["type":"input_video"]).merging(p["url"].present ? ["video_url":p["url"]] : p["file_id"].present ? ["file_id":p["file_id"]] : ["video_data":j(try mediaURI(p))])
        default: try unsupported("\(p["type"].s) as Responses input")
        }
    }
    static let openaiBuiltins = ["web_search":"web_search_preview","code_execution":"code_interpreter","file_search":"file_search","computer_use":"computer_use_preview"]
    func builtinType(_ t: J, _ c: J) -> J { c["builtin_tools"] == "verbatim" ? t["name"] : j(Self.openaiBuiltins[t["name"].s] ?? t["name"].s) }
    func markBlock(_ blocks: inout [J], _ type: String) throws { guard let last = blocks.last, last["type"].s == type else { try unsupported("cache breakpoint on this message") }; blocks[blocks.count-1]["prompt_cache_breakpoint"] = ["mode":"explicit"] }
    func chatPart(_ p: J) throws -> J {
        if p["type"] == "image" {
            if p["file_id"].present { try unsupported("image file_id on Chat Completions") }
            var image: J = ["url":p["url"].present ? p["url"] : j(try mediaURI(p))]; if p["detail"].present { image["detail"] = p["detail"] }; return ["type":"image_url","image_url":image]
        }; return ["type":"text","text":j(try partsText([p]))]
    }
    func chatMessages(_ r: J, _ c: J) throws -> [J] {
        let mark = c["cache_control"] == "openai" ? cacheMark(r) : nil; var rows: [J] = []
        if r["system"].present { let text = j(try systemText(r)); rows.append(["role":c["instruction_role"],"content":mark == -1 ? [["type":"text","text":text,"prompt_cache_breakpoint":["mode":"explicit"]]] : text]) }
        for (i,m) in r["messages"].a.enumerated() {
            if mark == i && ["assistant","tool"].contains(m["role"].s) { try unsupported("cache breakpoint on assistant or tool message") }
            switch m["role"].s {
            case "tool": for p in m["parts"].a {
                var row: J = ["role":"tool","tool_call_id":p["id"],"content":try toolOutput(p,c["tool_result_media"],textType:"text",convert:chatPart)]
                if c["tool_result_name"] == "include" && p["name"].present { row["name"] = p["name"] }; rows.append(row)
            }
            case "assistant":
                let words = m["parts"].a.filter { ["text","refusal"].contains($0["type"].s) || $0["type"] == "thinking" && c["thinking_replay"] == "as_text" && !$0["text"].empty }.map { $0["text"].s }
                var row: J = ["role":"assistant","content":words.isEmpty ? .null : j(words.joined(separator:"\n"))]
                if c["thinking_replay"] == "native" { let thought = m["parts"].a.filter { $0["type"] == "thinking" && !$0["text"].empty }.map { $0["text"].s }.joined(separator:"\n"); if !thought.isEmpty || c["assistant_reasoning_content"] == "include_empty" { row["reasoning_content"] = j(thought) } }
                let calls: [J] = try m["parts"].a.filter { $0["type"] == "tool_call" }.map { ["id":$0["id"],"type":"function","function":["name":$0["name"],"arguments":j(try $0["input"].jsonString())]] }
                if !calls.isEmpty { row["tool_calls"] = arr(calls) }; rows.append(row)
            default:
                var content: J
                if m["parts"].a.count == 1 && m["parts"][0]["type"] == "text" && mark != i { content = m["parts"][0]["text"] }
                else { var blocks = try m["parts"].a.filter { $0["type"] != "thinking" }.map(chatPart); if mark == i { try markBlock(&blocks,"text") }; content = arr(blocks) }
                if !content.isArray || !content.empty { rows.append(["role":m["role"] == "developer" ? c["instruction_role"] : m["role"],"content":content]) }
            }
        }
        if c["assistant_after_tool_result"] == "empty" && rows.last?["role"] == "tool" { rows.append(["role":"assistant","content":""]) }; return rows
    }
    func openaiToolChoice(_ r: J, _ c: J, chat: Bool = false) throws -> J {
        let tc = r["config"]["tool_choice"]; if tc.isNull { return .null }; if tc["allowed"].empty { return tc["mode"] }
        let entries = try tc["allowed"].a.map { name -> J in
            let t = r["tools"].a.first { $0["name"] == name }!
            if t["type"] == "builtin" { if chat { try unsupported("forcing builtin tools on Chat Completions") }; return ["type":builtinType(t,c)] }
            return chat ? ["type":"function","function":["name":t["name"]]] : ["type":"function","name":t["name"]]
        }
        if entries.count == 1 && tc["mode"] == "required" { return entries[0] }
        let body: J = ["mode":tc["mode"],"tools":arr(entries)]; return chat ? ["type":"allowed_tools","allowed_tools":body] : J.object(["type":"allowed_tools"]).merging(body)
    }
    func openaiReasoning(_ p: inout J, _ reason: J, _ c: J, chat: Bool = false) throws {
        if reason.isNull { return }; let format = c[chat ? "thinking_format" : "reasoning_format"].s, off = reason["effort"] == "off"
        if format == "none" { try unsupported("reasoning on this endpoint") }
        if !off {
            if reason["thinking_budget"].present { try unsupported("thinking_budget on this endpoint") }
            if ["concise","detailed"].contains(reason["summary"].s) && format != "responses_reasoning" { try unsupported("reasoning summary detail") }
            if c["reasoning_efforts"].present && !c["reasoning_efforts"].a.contains(reason["effort"]) { try unsupported("reasoning effort \(reason["effort"].s)") }
        }
        let effort: J = off ? "none" : reason["effort"]
        switch format {
        case "responses_reasoning": p["reasoning"] = ["effort":effort]; if !off && reason["summary"].present { p["reasoning"]["summary"] = reason["summary"] }
        case "reasoning_effort": p["reasoning_effort"] = effort
        case "openrouter": p["reasoning"] = off ? ["enabled":false] : ["effort":effort]
        case "deepseek": p["thinking"] = ["type":off ? "disabled" : "enabled"]; if !off { p["reasoning_effort"] = effort }
        case "kimi": if off { p["thinking"] = ["type":"disabled"] } else { p["reasoning_effort"] = effort }
        case "qwen","zai": p["enable_thinking"] = j(!off)
        case "qwen_chat_template": p["chat_template_kwargs"] = ["enable_thinking":j(!off)]; if !off { p["chat_template_kwargs"]["preserve_thinking"] = true }
        default: break
        }
        if chat && c["builtin_tools"] == "groq" && !off && reason["summary"] == "auto" { p["reasoning_format"] = "parsed" }
    }
    func formatSchema(_ f: J) -> J { var h: J = ["name":f["name"].empty ? "response" : f["name"],"schema":f["schema"]]; if f.has("strict") { h["strict"] = f["strict"] }; return h }
    func chatPayload(_ r: J, _ stream: Bool) throws -> J {
        let c = try compatible(r), conf = r["config"], tc = conf["tool_choice"]
        if provider == "xai" {
            if conf["reasoning"]["effort"] == "off" { try unsupported("reasoning off on xAI") }
            if tc.present && !tc["allowed"].empty && !(tc["allowed"].a.count == 1 && tc["mode"] == "required") { try unsupported("tool allowlists on xAI") }
            if tc["mode"] == "required" && conf["response_format"].present { try unsupported("forced tool with response_format on xAI") }
        }
        var p: J = ["model":r["model"],"messages":arr(try chatMessages(r,c))]
        if stream { p["stream"] = true }; if stream && c["stream_usage"] == "include" { p["stream_options"] = ["include_usage":true] }
        if conf["max_tokens"].present { p[c["max_tokens_field"].s] = conf["max_tokens"] }
        for k in ["temperature","top_p","service_tier","store"] where conf[k].present { p[k] = conf[k] }
        if conf["user_id"].present { p[c["user_field"].s] = conf["user_id"] }; if conf["top_k"].present { try unsupported("top_k") }; if !conf["stop"].empty { p["stop"] = conf["stop"] }
        if conf["logprobs"].present { if provider == "xai" { try unsupported("logprobs") }; p["logprobs"] = true; if conf["logprobs"].i > 0 { p["top_logprobs"] = conf["logprobs"] } }
        if !r["tools"].empty {
            p["tools"] = arr(try r["tools"].a.map { t in
                if t["type"] == "builtin" { let map = ["web_search":"browser_search","code_execution":"code_interpreter"]; guard c["builtin_tools"] == "groq", let type = map[t["name"].s] else { try unsupported("builtin tool \(t["name"].s)") }; return J.object(["type":j(type)]).merging(t["config"]) }
                var f: J = ["name":t["name"],"description":t["description"],"parameters":t["parameters"]]; if c["strict_tools"] == "include" { f["strict"] = false }; return ["type":"function","function":f]
            })
        }
        if tc.present { if c["forced_tool_choice"] == "reject" && (tc["mode"] != "auto" || !tc["allowed"].empty) { try unsupported("tool_choice") }; p["tool_choice"] = try openaiToolChoice(r,c,chat:true); if tc["parallel"].present { p["parallel_tool_calls"] = tc["parallel"] } }
        let f = conf["response_format"]
        if f.present { if c["json_schema"] == "reject" && f["type"] == "json_schema" { try unsupported("json_schema") }; p["response_format"] = f["type"] == "json_object" ? ["type":"json_object"] : ["type":"json_schema","json_schema":formatSchema(f)] }
        try openaiReasoning(&p,conf["reasoning"],c,chat:true); try openaiCache(&p,r,c["cache_control"]); if c["routing"].present { p["provider"] = c["routing"] }; return extensions(p,conf,c)
    }
    func responsesInput(_ r: J, _ c: J) throws -> [J] {
        let mark = c["cache_control"] == "openai" ? cacheMark(r) : nil; var items: [J] = []
        for (i,m) in r["messages"].a.enumerated() {
            if mark == i && ["assistant","tool"].contains(m["role"].s) { try unsupported("cache breakpoint on assistant or tool message") }
            if m["role"] == "tool" {
                for p in m["parts"].a { var row: J = ["type":"function_call_output","call_id":p["id"],"output":try toolOutput(p,c["tool_result_media"],convert:openaiInput)]; if c["tool_result_name"] == "include" && p["name"].present { row["name"] = p["name"] }; items.append(row) }; continue
            }
            var content: [J] = []
            if m["role"] == "assistant" {
                for p in m["parts"].a {
                    switch p["type"].s {
                    case "text": content.append(["type":"output_text","text":p["text"]])
                    case "refusal": content.append(["type":"refusal","refusal":p["text"]])
                    case "thinking":
                        let state = continuationData(p,"openai","reasoning_item")
                        if state.present { items.append(J.object(["type":"reasoning"]).merging(.object(state.o.filter { ["id","encrypted_content"].contains($0.key) })).with("summary",p["text"].empty ? [] : [["type":"summary_text","text":p["text"]]])) }
                        else if !p["text"].empty { content.append(["type":"output_text","text":p["text"]]) }
                    default: break
                    }
                }
            } else { content = try m["parts"].a.map(openaiInput) }
            if mark == i { try markBlock(&content,"input_text") }
            if !content.isEmpty { var row: J = ["role":m["role"] == "developer" ? c["developer_role"] : m["role"],"content":arr(content)]; if c["commentary_phase"] == "tag" && m["role"] == "assistant" && m["parts"].a.contains(where: { $0["type"] == "tool_call" }) { row["phase"] = "commentary" }; items.append(row) }
            for p in m["parts"].a where p["type"] == "tool_call" { items.append(["type":"function_call","call_id":p["id"],"name":p["name"],"arguments":j(try p["input"].jsonString())]) }
        }
        if r["system"].present && mark == -1 { items.insert(["role":c["developer_role"],"content":[["type":"input_text","text":j(try systemText(r)),"prompt_cache_breakpoint":["mode":"explicit"]]]] ,at:0) }; return items
    }
    func responsesPayload(_ r: J, _ stream: Bool) throws -> J {
        let c = try compatible(r), conf = r["config"]; var p: J = ["model":r["model"],"input":arr(try responsesInput(r,c)),"stream":j(stream)]
        if r["system"].present && !(c["cache_control"] == "openai" && cacheMark(r) == -1) { p["instructions"] = j(try systemText(r)) }
        if conf["max_tokens"].present { p[c["max_output_tokens_field"].s] = conf["max_tokens"] }
        for k in ["temperature","top_p","service_tier","store"] where conf[k].present { p[k] = conf[k] }
        if conf["user_id"].present { p["safety_identifier"] = conf["user_id"] }
        if !conf["stop"].empty { try unsupported("stop sequences on Responses") }; if conf["top_k"].present { try unsupported("top_k on Responses") }
        if conf["logprobs"].present { p["top_logprobs"] = conf["logprobs"]; p["include"] = ["message.output_text.logprobs"] }
        if !r["tools"].empty { p["tools"] = arr(r["tools"].a.map { t in
            if t["type"] == "builtin" { var out: J = ["type":builtinType(t,c)]; if out["type"] == "code_interpreter" { out["container"] = ["type":"auto"] }; return out.merging(t["config"]) }
            var out: J = ["type":"function","name":t["name"],"description":t["description"],"parameters":t["parameters"]]; if c["strict_tools"] == "include" { out["strict"] = false }; return out
        }) }
        let tc = conf["tool_choice"]
        if tc.present { p["tool_choice"] = try openaiToolChoice(r,c); if tc["parallel"].present { p["parallel_tool_calls"] = tc["parallel"] } }
        let f = conf["response_format"]; if f.present { p["text"] = ["format":f["type"] == "json_object" ? ["type":"json_object"] : J.object(["type":"json_schema"]).merging(formatSchema(f))] }
        try openaiReasoning(&p,conf["reasoning"],c); try openaiCache(&p,r,c["cache_control"])
        if c["routing"].present { p["provider"] = c["routing"] }; p = extensions(p,conf,c)
        if provider == "openai-codex" { if p["instructions"].isNull { p["instructions"] = access.value["system_prefix"] }; p["store"] = false; p["stream"] = true; p = p.without(["max_tokens","max_completion_tokens","max_output_tokens"]) }; return p
    }
}
