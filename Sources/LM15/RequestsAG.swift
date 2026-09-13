import Foundation

extension ProviderLM {
    func anthropicSource(_ p: J) throws -> J {
        if p["url"].present { return ["type":"url","url":p["url"]] }; if p["file_id"].present { return ["type":"file","file_id":p["file_id"]] }
        return ["type":"base64","media_type":p["media_type"],"data":j(try mediaBase64(p))]
    }
    func anthropicPart(_ p: J, _ c: J) throws -> J {
        switch p["type"].s {
        case "text","refusal": return ["type":"text","text":p["text"]]
        case "image","document": return ["type":p["type"],"source":try anthropicSource(p)]
        case "audio","video","binary": try unsupported("\(p["type"].s) on Anthropic")
        case "tool_call": return ["type":"tool_use","id":p["id"],"name":p["name"],"input":p["input"]]
        case "tool_result":
            try checkToolMedia(p,c["tool_result_media"])
            let blocks: [J] = try p["content"].a.map { x in ["image","document"].contains(x["type"].s) ? try anthropicPart(x,c) : ["type":"text","text":j(try partsText([x]))] }
            var row: J = ["type":"tool_result","tool_use_id":p["id"],"content":blocks.count == 1 && blocks[0]["type"] == "text" ? blocks[0]["text"] : arr(blocks)]
            if p["is_error"].b { row["is_error"] = true }; return row
        case "thinking":
            let redacted = continuationData(p,"anthropic","redacted_thinking"), signature = continuationData(p,"anthropic","thinking_signature")
            if redacted.present { return J.object(["type":"redacted_thinking"]).merging(redacted) }
            if signature["signature"].present { return ["type":"thinking","thinking":p["text"],"signature":signature["signature"]] }
            if c["thinking_replay"] == "unsigned" && !p["text"].empty { return ["type":"thinking","thinking":p["text"]] }; return ["type":"text","text":p["text"]]
        default: return ["type":"text","text":p["text"].or("")]
        }
    }
    func anthropicPayload(_ r: J, _ stream: Bool) throws -> J {
        let c = try compatible(r), conf = r["config"]
        if c["model_prefixes"].present && !c["model_prefixes"].a.contains(where: { r["model"].s.hasPrefix($0.s) }) { throw UnsupportedModelError("\(provider): model would be substituted") }
        var rows: [J] = try r["messages"].a.map { m in
            let blocks: [J] = m["role"] == "developer" ? [["type":"text","text":j("[developer]\n" + (try partsText(m["parts"].a)))]] : try m["parts"].a.map { try anthropicPart($0,c) }
            return ["role":m["role"] == "assistant" ? "assistant" : "user","content":arr(blocks)]
        }
        let cache = conf["cache"], useCache = cache.present && cache["mode"] != "off" && c["cache_control"] == "anthropic"
        var marker: J = ["type":"ephemeral"]; if cache["retention"] == "long" { marker["ttl"] = "1h" }
        if useCache {
            if cache["key"].present || cache["resource"].present { try unsupported("cache key or resource on Anthropic") }
            let index: Int? = cache["prefix"] == "history" ? rows.count-1 : cache["prefix_until_index"].present ? min(cache["prefix_until_index"].i,rows.count-1) : nil
            if let i = index, !rows[i]["content"].empty { var blocks = rows[i]["content"].a; blocks[blocks.count-1]["cache_control"] = marker; rows[i]["content"] = arr(blocks) }
        }
        let reason = conf["reasoning"], format = c["thinking_format"].s
        let special = ["deepseek","adaptive","effort"].contains(format)
        let markers = ["sonnet-5","opus-5","sonnet-4-6","opus-4-6","opus-4-7","opus-4-8","fable","mythos","haiku-5"]
        let adaptive = reason.present && reason["effort"] != "off" && (special || markers.contains(where:r["model"].s.lowercased().contains))
        var budget: J = .null
        if reason.present && reason["effort"] != "off" {
            if c["reasoning_efforts"].present && !c["reasoning_efforts"].a.contains(reason["effort"]) { try unsupported("reasoning effort \(reason["effort"].s)") }
            if ["concise","detailed"].contains(reason["summary"].s) { try unsupported("reasoning summary detail") }
            if adaptive && reason["thinking_budget"].present { try unsupported("thinking_budget on adaptive models") }
            if adaptive && reason["effort"] == "minimal" && !special { try unsupported("minimal effort on adaptive Anthropic models") }
            if !adaptive { budget = reason["thinking_budget"].or(Tables.data["effort_budgets"][reason["effort"].s]) }
        }
        var p: J = ["model":r["model"],"messages":arr(rows),"stream":j(stream),"max_tokens":j(conf["max_tokens"].or(1024).i+budget.i)]
        if r["system"].present { let text = j(try systemText(r)); p["system"] = useCache ? [["type":"text","text":text,"cache_control":marker]] : text }
        for k in ["temperature","top_p","top_k"] where conf[k].present { if c["sampling_params"] == "reject" { try unsupported("\(k) on this endpoint") }; p[k] = conf[k] }
        if !conf["stop"].empty { p["stop_sequences"] = conf["stop"] }
        if !r["tools"].empty { p["tools"] = arr(r["tools"].a.map { t in
            t["type"] == "builtin" ? J.object(["type":j(["web_search":"web_search_20250305","code_execution":"code_execution_20250522"][t["name"].s] ?? t["name"].s),"name":t["name"]]).merging(t["config"]) : ["name":t["name"],"description":t["description"],"input_schema":t["parameters"]]
        }) }
        let tc = conf["tool_choice"]
        if tc.present {
            if c["parallel_tool_calls"] == "reject" && tc["parallel"].present { try unsupported("parallel tool preference") }
            var choice: J = ["type":j(["none":"none","auto":"auto","required":"any"][tc["mode"].s]!)]
            if !tc["allowed"].empty {
                if tc["allowed"].a.count == 1 && tc["mode"] == "required" { choice = ["type":"tool","name":tc["allowed"][0]] }
                else if tc["allowed"].a.map(\.s).sorted() != r["tools"].a.map({ $0["name"].s }).sorted() { try unsupported("tool allowlist subset") }
            }
            if tc["parallel"] == false && tc["mode"] != "none" { choice["disable_parallel_tool_use"] = true }; p["tool_choice"] = choice
        }
        if reason.present {
            if reason["effort"] == "off" { if special { p["thinking"] = ["type":"disabled"] } }
            else if adaptive { if format != "effort" { p["thinking"] = ["type":format == "deepseek" ? "enabled" : "adaptive"] }; p["output_config"] = ["effort":reason["effort"]] }
            else if budget.present { p["thinking"] = ["type":"enabled","budget_tokens":budget] }
        }
        let f = conf["response_format"]
        if f.present { if c["structured_output"] == "reject" || f["type"] == "json_object" { try unsupported("response_format") }; p["output_config"]["format"] = ["type":"json_schema","schema":f["schema"]] }
        if conf["store"].present { try unsupported("store") }; if conf["logprobs"].present { try unsupported("logprobs") }
        if conf["service_tier"].present { p["service_tier"] = conf["service_tier"] }; if conf["user_id"].present { p["metadata"] = ["user_id":conf["user_id"]] }
        p = extensions(p,conf,c)
        if access.value["system_prefix"].present { let previous = p["system"]; p["system"] = arr([["type":"text","text":access.value["system_prefix"]]] + (previous.isNull ? [] : previous.isArray ? previous.a : [["type":"text","text":previous]])) }; return p
    }
    func geminiPart(_ p: J, _ names: J = [:]) throws -> J {
        var out: J
        switch p["type"].s {
        case "text","thinking","refusal": out = ["text":p["text"]]
        case "image","audio","video","document","binary":
            out = p["url"].present || p["file_id"].present ? ["fileData":["mimeType":p["media_type"],"fileUri":p["url"].or(p["file_id"])]] : ["inlineData":["mimeType":p["media_type"],"data":j(try mediaBase64(p))]]
        case "tool_call": out = ["functionCall":["name":p["name"],"args":p["input"],"id":p["id"]]]
        case "tool_result":
            let name = p["name"].or(names[p["id"].s]); if name.isNull { try unsupported("tool result without a name or preceding call") }
            let media = p["content"].a.filter { Canonical.media.contains($0["type"].s) }, words = p["content"].a.filter { !Canonical.media.contains($0["type"].s) }; try checkToolMedia(p,"native")
            let response: J = p["is_error"].b ? ["error":j(try partsText(words))] : !media.isEmpty && words.isEmpty ? [:] : ["result":j(try partsText(words))]
            var fr: J = ["name":name,"response":response,"id":p["id"]]; if !media.isEmpty { fr["parts"] = arr(try media.map { try geminiPart($0,names) }) }; out = ["functionResponse":fr]
        default: out = ["text":p["text"].or("")]
        }
        if ["text","thinking","tool_call"].contains(p["type"].s) { let state = continuationData(p,"gemini","thought_signature"); if state["value"].present { out["thoughtSignature"] = state["value"]; if p["type"] == "thinking" { out["thought"] = true } } }; return out
    }
    func geminiPayload(_ r: J) throws -> J {
        let conf = r["config"], cache = conf["cache"]; var resource: J = .null, start = 0
        if cache.present && cache["mode"] != "off" {
            if cache["key"].present { try unsupported("cache key") }; if cache["retention"].present && cache["retention"] != "short" { try unsupported("cache retention in request") }
            resource = cache["resource"]; if resource.present && cache["prefix_until_index"].present { start = min(cache["prefix_until_index"].i,r["messages"].a.count-1)+1 }
        }
        let messages = Array(r["messages"].a.dropFirst(start)); if resource.present && messages.isEmpty { throw ValueError("stored-cache request requires a suffix message") }
        var names: J = [:]; for m in r["messages"].a { for p in m["parts"].a where p["type"] == "tool_call" { names[p["id"].s] = p["name"] } }
        var p: J = ["contents":arr(try messages.map { m in
            let parts: [J] = m["role"] == "developer" ? [["text":j("[developer]\n" + (try partsText(m["parts"].a)))]] : try m["parts"].a.map { try geminiPart($0,names) }
            return ["role":m["role"] == "assistant" ? "model" : "user","parts":arr(parts)]
        })]
        if resource.present { p["cachedContent"] = j(resource.s.hasPrefix("cachedContents/") ? resource.s : "cachedContents/"+resource.s) }
        if r["system"].present && resource.isNull { p["systemInstruction"] = ["parts":[["text":j(try systemText(r))]]] }
        var g: J = [:]
        for (from,to) in ["temperature":"temperature","max_tokens":"maxOutputTokens","top_p":"topP","top_k":"topK"] where conf[from].present { let v = conf[from]; g[to] = v.isNumber && v.d.rounded(.towardZero) == v.d ? j(v.i) : v }
        if !conf["stop"].empty { g["stopSequences"] = conf["stop"] }
        if conf["logprobs"].present { g["responseLogprobs"] = true; if conf["logprobs"].i > 0 { g["logprobs"] = conf["logprobs"] } }
        let f = conf["response_format"]
        if f.present { g["responseMimeType"] = "application/json"; if f["type"] == "json_schema" { if f["strict"] == false { try unsupported("response_format.strict=false on Gemini") }; g[containsKey(f["schema"],"additionalProperties") ? "responseJsonSchema" : "responseSchema"] = f["schema"] } }
        let reason = conf["reasoning"]
        if reason.present {
            let model = r["model"].s.hasPrefix("models/") ? String(r["model"].s.dropFirst(7)) : r["model"].s, level = model.lowercased().hasPrefix("gemini-3")
            if reason["effort"] == "off" { if level { try unsupported("reasoning off on Gemini 3") }; g["thinkingConfig"] = ["thinkingBudget":0] }
            else {
                if ["concise","detailed"].contains(reason["summary"].s) { try unsupported("reasoning summary detail") }
                var thinking: J = [:]; if reason["summary"].present { thinking["includeThoughts"] = true }
                if reason["thinking_budget"].present { thinking["thinkingBudget"] = reason["thinking_budget"] }
                else if level { if ["xhigh","max"].contains(reason["effort"].s) { try unsupported("reasoning effort \(reason["effort"].s)") }; thinking["thinkingLevel"] = reason["effort"] }
                else { thinking["thinkingBudget"] = Tables.data["effort_budgets"][reason["effort"].s] }; g["thinkingConfig"] = thinking
            }
        }
        if !g.empty { p["generationConfig"] = g }
        if resource.isNull {
            let functions: [J] = r["tools"].a.filter { $0["type"] == "function" }.map { ["name":$0["name"],"description":$0["description"],"parameters":$0["parameters"]] }
            var ts: [J] = functions.isEmpty ? [] : [["functionDeclarations":arr(functions)]]
            ts += r["tools"].a.filter { $0["type"] == "builtin" }.map { .object([["web_search":"googleSearch","code_execution":"codeExecution"][$0["name"].s] ?? $0["name"].s : $0["config"].or([:])]) }
            if !ts.isEmpty { p["tools"] = arr(ts) }
            let tc = conf["tool_choice"]
            if tc.present {
                if tc["parallel"] == false { try unsupported("parallel=false on Gemini") }; var cfg: J = ["mode":j(["none":"NONE","required":"ANY","auto":"AUTO"][tc["mode"].s]!)]
                if !tc["allowed"].empty { if r["tools"].a.contains(where: { tc["allowed"].a.contains($0["name"]) && $0["type"] == "builtin" }) { try unsupported("forcing builtin tools on Gemini") }; cfg["allowedFunctionNames"] = tc["allowed"]; if tc["mode"] == "auto" { cfg["mode"] = "VALIDATED" } }
                p["toolConfig"] = ["functionCallingConfig":cfg]
            }
        }
        if conf["user_id"].present { try unsupported("user_id on Gemini") }; if conf["store"].present { p["store"] = conf["store"] }; if conf["service_tier"].present { p["serviceTier"] = conf["service_tier"] }
        let ext = conf["extensions"]; if ["image","audio"].contains(ext["output"].s) { p["generationConfig"]["responseModalities"] = [j(ext["output"].s.uppercased())] }
        return p.merging(ext.without(["prompt_caching","output"]))
    }
}
func containsKey(_ v: J, _ key: String) -> Bool { v.has(key) || v.o.values.contains { containsKey($0,key) } || v.a.contains { containsKey($0,key) } }
