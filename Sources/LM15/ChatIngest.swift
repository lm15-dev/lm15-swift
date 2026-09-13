import Foundation

/// Strict MAP-12 conversion. Unmapped caller fields are refused at the boundary.
struct ChatIngest {
    let lm: ProviderLM
    var compat: J = [:]
    static let extensions = ["seed","logit_bias","presence_penalty","frequency_penalty","metadata","verbosity","moderation","provider"]
    static let config = ["model","messages","tools","tool_choice","parallel_tool_calls","max_completion_tokens","max_tokens","temperature","top_p","stop","logprobs","top_logprobs","response_format","service_tier","store","user","safety_identifier","user_id","reasoning_effort","reasoning","thinking","enable_thinking","chat_template_kwargs","reasoning_format","prompt_cache_key","prompt_cache_retention","prompt_cache_options"]
    static let clientKeys = ["provider_specific_fields","thinking_blocks","images"]
    func unsupported(_ key: String) throws -> Never { throw UnsupportedFeatureError("\(key) has no canonical mapping for this provider",metadata:["provider":j(lm.provider)]) }
    @discardableResult func object(_ v: J, _ where_: String) throws -> J { guard v.isObject else { throw TypeError("\(where_) must be an object") }; return v }
    func string(_ v: J, _ where_: String) throws -> J { guard v.isString else { throw TypeError("\(where_) must be a string") }; return v }
    func array(_ v: J, _ where_: String) throws -> [J] { guard v.isArray else { throw TypeError("\(where_) must be an array") }; return v.a }
    @discardableResult func keys(_ d: J, _ allowed: [String], _ where_: String) throws -> J { try object(d,where_); if let extra = Set(d.o.keys).subtracting(allowed).sorted().first { try unsupported(where_+"."+extra) }; return d }
    func dataURI(_ s: String) throws -> J { guard s.hasPrefix("data:"), let range = s.range(of:";base64,"), range.lowerBound > s.index(s.startIndex,offsetBy:5), range.upperBound < s.endIndex else { throw ValueError("invalid base64 data URI") }; return ["media_type":j(String(s[s.index(s.startIndex,offsetBy:5)..<range.lowerBound])),"data":j(String(s[range.upperBound...]))] }
    func content(_ value: J, _ role: String) throws -> (parts:[J], marked:Bool) {
        if value.isString { return ([["type":"text","text":value]],false) }; let blocks = try array(value,"content"); var marked = false
        let parts = try blocks.enumerated().map { i,b -> J in
            try object(b,"content block"); let kind = b["type"]
            if b["prompt_cache_breakpoint"].present { guard b["prompt_cache_breakpoint"] == ["mode":"explicit"] && kind == "text" && i == blocks.count-1 else { throw ValueError("cache breakpoint must mark the last text block") }; marked = true }
            switch kind.s {
            case "text": try keys(b,["type","text","prompt_cache_breakpoint"],"text"); return ["type":"text","text":try string(b["text"],"text")]
            case "image_url":
                if !["user","tool"].contains(role) { try unsupported(role+".image_url") }; try keys(b,["type","image_url","prompt_cache_breakpoint"],"image_url"); let spec = try keys(b["image_url"],["url","detail"],"image_url"), url = try string(spec["url"],"image_url.url").s
                var attrs: J
                if url.hasPrefix("data:") { attrs = try dataURI(url) } else { attrs = ["url":j(url)]; let ext = (url as NSString).pathExtension.lowercased(); if let mime = ["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","webp":"image/webp","svg":"image/svg+xml","bmp":"image/bmp","tiff":"image/tiff"][ext] { attrs["media_type"] = j(mime) } }
                attrs["detail"] = spec["detail"]; return try Canonical.normalize("ImagePart",attrs)
            case "input_audio":
                if role != "user" { try unsupported(role+".input_audio") }; try keys(b,["type","input_audio","prompt_cache_breakpoint"],"input_audio"); let spec = try keys(b["input_audio"],["data","format"],"input_audio")
                guard let mime = ["wav":"audio/wav","mp3":"audio/mpeg"][spec["format"].s] else { throw ValueError("input_audio.format must be wav or mp3") }; return try Canonical.normalize("AudioPart",["data":string(spec["data"],"input_audio.data"),"media_type":j(mime)])
            case "file":
                if role != "user" { try unsupported(role+".file") }; try keys(b,["type","file","prompt_cache_breakpoint"],"file"); let spec = try keys(b["file"],["file_data","file_id","filename"],"file")
                if spec["filename"].present { try unsupported("file.filename") }; if [spec["file_data"],spec["file_id"]].filter(\.present).count != 1 { throw ValueError("file needs exactly one source") }
                return try Canonical.normalize("DocumentPart",spec["file_id"].present ? ["file_id":string(spec["file_id"],"file.file_id")] : dataURI(string(spec["file_data"],"file.file_data").s))
            case "refusal": if role != "assistant" { try unsupported(role+".refusal") }; try keys(b,["type","refusal"],"refusal"); return ["type":"refusal","text":try string(b["refusal"],"refusal")]
            default: try unsupported(role+".content.type="+kind.s)
            }
        }; return (parts,marked)
    }
    func calls(_ raw: J) throws -> [J] {
        try array(raw,"tool_calls").map { call in
            try keys(call,["id","type","function"],"tool_calls"); if call["type"].or("function") != "function" { try unsupported("tool_calls.type") }
            let f = try keys(call["function"],["name","arguments"],"tool_calls.function"); var args = f["arguments"].or("{}")
            if args.isString { guard let parsed = try? J.parse(args.empty ? "{}" : args.s) else { throw ValueError("tool-call arguments are not JSON") }; args = parsed }
            guard args.isObject else { throw ValueError("tool-call arguments must be an object") }
            return ["type":"tool_call","id":try string(call["id"],"call.id"),"name":try string(f["name"],"function.name"),"input":args]
        }
    }
    func annotations(_ raw: J, _ text: J) throws -> [J] {
        try array(raw,"annotations").map { entry in
            try keys(entry,["type","url_citation"],"annotations"); if entry["type"] != "url_citation" { try unsupported("annotations.type") }
            let s = try keys(entry["url_citation"],["url","title","start_index","end_index"],"url_citation")
            let excerpt = text.isString && wireType(s["start_index"]) == "int" && wireType(s["end_index"]) == "int" ? sliceText(text.s,s["start_index"].i,s["end_index"].i) : .null
            return ["type":"citation","url":try string(s["url"],"citation.url"),"title":s["title"].isNull ? .null : try string(s["title"],"citation.title"),"text":nonempty(excerpt)]
        }
    }
    func messages(_ rows: J) throws -> (system:J, messages:[J], systemMark:Bool, index:Int?) {
        var messages: [J] = [], system: J = .null, systemMark = false, index: Int?, pending: [J] = []
        func flush() { if !pending.isEmpty { messages.append(["role":"tool","parts":arr(pending)]); pending = [] } }
        for (i,row) in try array(rows,"messages").enumerated() {
            try object(row,"message"); let role = row["role"].s; if row["name"].present && role != "tool" { try unsupported("message.name") }
            switch role {
            case "system","developer","user":
                flush(); try keys(row,role == "user" ? ["role","content","name"] : ["role","content"],"message")
                let (parts,mark) = try content(row["content"],role == "user" ? "user" : "system")
                if i == 0 && role != "user" { system = parts.count == 1 && parts[0]["type"] == "text" ? parts[0]["text"] : arr(parts); systemMark = mark }
                else { if mark && role == "user" && (systemMark || index != nil) { throw ValueError("only one prompt cache breakpoint is allowed") }; if mark { index = messages.count }; messages.append(["role":role == "user" ? "user" : "developer","parts":arr(parts)]) }
            case "assistant":
                flush(); try keys(row,["role","content","tool_calls","refusal","reasoning_content","name","audio","function_call","annotations"]+Self.clientKeys,"assistant")
                for k in ["audio","function_call"] where row[k].present { try unsupported("assistant."+k) }
                for k in Self.clientKeys { let v = row[k]; let empty = v.isNull || v == [] || v == [:] || v.isObject && v.o.values.allSatisfy { $0.isNull || $0 == [] || $0 == [:] }; if !empty { try unsupported("assistant."+k) } }
                var parts: [J] = []
                if row["reasoning_content"].present { parts.append(["type":"thinking","text":try string(row["reasoning_content"],"reasoning_content")]) }
                if row["content"].present { let (more,mark) = try content(row["content"],"assistant"); if mark { throw ValueError("assistant cache breakpoint is invalid") }; parts += more }
                if row["refusal"].present { parts.append(["type":"refusal","text":try string(row["refusal"],"refusal")]) }
                if row["tool_calls"].present { parts += try calls(row["tool_calls"]) }; if row["annotations"].present { parts += try annotations(row["annotations"],row["content"]) }
                if parts.isEmpty { parts.append(["type":"text","text":""]) }; messages.append(["role":"assistant","parts":arr(parts)])
            case "tool":
                try keys(row,["role","content","tool_call_id","name"],"tool"); let (parts,mark) = try content(row["content"],"tool"); if mark { throw ValueError("tool cache breakpoint is invalid") }
                pending.append(["type":"tool_result","id":try string(row["tool_call_id"],"tool_call_id"),"content":arr(parts),"name":row["name"].isNull ? .null : try string(row["name"],"tool.name")])
            case "function": try unsupported("message.role=function")
            default: throw ValueError("invalid message role")
            }
        }; flush(); return (system,messages,systemMark,index)
    }
    func tools(_ raw: J) throws -> [J] {
        if raw.isNull { return [] }; return try array(raw,"tools").map { t in
            try object(t,"tool")
            if t["type"] == "function" {
                try keys(t,["type","function"],"tool"); let f = try keys(t["function"],["name","description","parameters","strict"],"function"); if f["strict"] == true { try unsupported("function.strict=true") }
                var attrs: J = ["name":try string(f["name"],"function.name")]; if f["description"].present { attrs["description"] = try string(f["description"],"function.description") }; if f["parameters"].present { attrs["parameters"] = try object(f["parameters"],"function.parameters") }; return try Canonical.normalize("FunctionTool",attrs)
            }
            if compat["builtin_tools"] == "groq", let name = ["browser_search":"web_search","code_interpreter":"code_execution"][t["type"].s] { let conf = t.without(["type"]); return ["type":"builtin","name":j(name),"config":conf.empty ? .null : conf] }
            try unsupported("tools.type="+t["type"].s)
        }
    }
    func choice(_ raw: J, _ parallel: J) throws -> J {
        var mode: J = .null, allowed: [J] = []
        if raw.present {
            if ["none","auto","required"].contains(raw.s) && raw.isString { mode = raw }
            else if raw.isObject {
                switch raw["type"].s {
                case "function": try keys(raw,["type","function"],"tool_choice"); let f = try keys(raw["function"],["name"],"tool_choice.function"); mode = "required"; allowed = [try string(f["name"],"tool_choice.name")]
                case "allowed_tools":
                    try keys(raw,["type","allowed_tools"],"tool_choice"); let s = try keys(raw["allowed_tools"],["mode","tools"],"allowed_tools"); mode = try string(s["mode"],"allowed_tools.mode")
                    let entries = try array(s["tools"],"allowed_tools.tools"); if entries.isEmpty { throw ValueError("allowed_tools must not be empty") }
                    allowed = try entries.map { e in try object(e,"allowed tool"); if e["type"] != "function" { try unsupported("allowed tool type") }; return try string(object(e["function"],"function")["name"],"function.name") }
                case "custom":try unsupported("tool_choice.type=custom")
                default:throw ValueError("unknown tool_choice.type")
                }
            } else { throw ValueError("invalid tool_choice") }
        }
        guard parallel.isNull || parallel == true || parallel == false else { throw TypeError("parallel_tool_calls must be boolean") }
        return mode.isNull && parallel.isNull ? .null : ["mode":mode.or("auto"),"allowed":arr(allowed),"parallel":parallel]
    }
    func responseFormat(_ raw: J) throws -> J {
        try object(raw,"response_format")
        switch raw["type"].s {
        case "text","json_object":try keys(raw,["type"],"response_format");return raw["type"] == "text" ? .null : raw
        case "json_schema":
            try keys(raw,["type","json_schema"],"response_format"); let s = try keys(raw["json_schema"],["name","schema","strict","description"],"json_schema"); if s["description"].present { try unsupported("response_format.json_schema.description") }
            var out: J = ["type":"json_schema","schema":try object(s["schema"],"json_schema.schema")]; if s["name"].present && s["name"] != "response" { out["name"] = try string(s["name"],"json_schema.name") }
            if s["strict"].present { guard s["strict"] == true || s["strict"] == false else { throw TypeError("json_schema.strict must be boolean") }; out["strict"] = s["strict"] }; return out
        default:throw ValueError("unknown response_format.type")
        }
    }
    func reasoning(_ b: J) throws -> (J,J) {
        let present = Set(b.o.keys).intersection(["reasoning_effort","reasoning","thinking","enable_thinking","chat_template_kwargs","reasoning_format"])
        var allowed = ["reasoning_effort":["reasoning_effort"],"openrouter":["reasoning"],"deepseek":["thinking","reasoning_effort"],"kimi":["thinking","reasoning_effort"],"qwen":["enable_thinking"],"qwen_chat_template":["chat_template_kwargs"],"none":[]][compat["thinking_format"].s] ?? []
        if compat["builtin_tools"] == "groq" { allowed.append("reasoning_format") }; if let foreign = present.subtracting(allowed).sorted().first { try unsupported(foreign) }
        var effort: J = .null, off = false, ext: J = [:], summary: J = .null
        if present.contains("reasoning_effort") { let word = try string(b["reasoning_effort"],"reasoning_effort"); if word == "none" { off = true } else { effort = word } }
        if present.contains("thinking") {
            let s = try keys(b["thinking"],["type"],"thinking")
            switch s["type"].s { case "disabled":if effort.present { throw ValueError("contradictory thinking and effort") }; off = true; case "enabled":if effort.isNull && !off { try unsupported("thinking.type=enabled without effort") }; default:throw ValueError("invalid thinking.type") }
        }
        if present.contains("reasoning") { let s = try keys(b["reasoning"],["effort","enabled"],"reasoning"); if s["enabled"] == false { off = true } else if s["effort"].present { effort = try string(s["effort"],"reasoning.effort") } else { throw ValueError("reasoning needs effort or enabled:false") } }
        for key in ["enable_thinking","chat_template_kwargs"] where present.contains(key) { let v = key == "enable_thinking" ? b[key] : try keys(b[key],["enable_thinking","preserve_thinking"],key)["enable_thinking"]; if v == false { off = true } else if v == true { try unsupported(key+"=true without effort level") } else { throw TypeError(key+" requires boolean") } }
        if present.contains("reasoning_format") { if b["reasoning_format"] != "parsed" { try unsupported("reasoning_format") }; if effort.present { summary = "auto" } else { ext["reasoning_format"] = "parsed" } }
        return (off ? ["effort":"off"] : effort.present ? ["effort":effort,"summary":summary] : .null,ext)
    }
    func cache(_ b: J, _ systemMark: Bool, _ index: Int?) throws -> J {
        let marked = systemMark || index != nil, keys_ = Set(b.o.keys).intersection(["prompt_cache_key","prompt_cache_retention","prompt_cache_options"])
        if !marked && keys_.isEmpty { return .null }
        if !["openai","openai_implicit"].contains(compat["cache_control"].s) { try unsupported(keys_.sorted().first ?? "prompt_cache_breakpoint") }
        if marked && compat["cache_control"] != "openai" { try unsupported("prompt_cache_breakpoint") }
        let key = b["prompt_cache_key"]; var retention: J = .null, explicit = false
        if b.has("prompt_cache_retention") { if b["prompt_cache_retention"] != "24h" { try unsupported("prompt_cache_retention") }; retention = "long" }
        if b.has("prompt_cache_options") {
            let s = try keys(b["prompt_cache_options"],["mode","ttl"],"prompt_cache_options"); if s["ttl"].present { try unsupported("prompt_cache_options.ttl") }; if s["mode"] == "implicit" { try unsupported("prompt_cache_options.mode=implicit") }; if s["mode"] != "explicit" { throw ValueError("invalid prompt_cache_options.mode") }; explicit = true
        }
        if explicit && !marked { if key.present || retention.present { throw ValueError("cache off cannot have key or retention") }; return ["mode":"off"] }
        var attrs: J = ["key":key,"retention":retention]; if systemMark { attrs["prefix"] = "stable" }; if let index { attrs["prefix_until_index"] = j(index) }; return attrs
    }
    mutating func read(_ b: J) throws -> Request {
        try keys(b,Self.config+Self.extensions+["stream","stream_options"],"request")
        let model = b["model"]; guard model.isString && !model.empty else { throw ValueError("model must be a nonempty string") }; if !b.has("messages") { throw ValueError("messages is required") }
        compat = try lm.compatible(["model":model]); let (system,messages,mark,index) = try messages(b["messages"])
        var attrs = J.object(b.o.filter { ["temperature","top_p","service_tier","store","stop"].contains($0.key) })
        let limits = ["max_tokens","max_completion_tokens"].filter { b.has($0) }.map { b[$0] }; if Set(limits).count > 1 { throw ValueError("max_tokens and max_completion_tokens disagree") }; if let limit = limits.first { attrs["max_tokens"] = limit }
        if b["logprobs"] == true { attrs["logprobs"] = b["top_logprobs"].or(0) } else if b["logprobs"].present && b["logprobs"] != false { throw TypeError("logprobs must be boolean") } else if b.has("top_logprobs") { throw ValueError("top_logprobs requires logprobs:true") }
        if b.has("response_format") { attrs["response_format"] = try responseFormat(b["response_format"]) }; attrs["tool_choice"] = try choice(b["tool_choice"],b["parallel_tool_calls"])
        let users = Set(b.o.keys).intersection(["user","safety_identifier","user_id"]); if users.contains("user_id") && compat["user_field"] != "user_id" { try unsupported("user_id") }; if users.count > 1 { throw ValueError("only one end-user identifier is allowed") }; if let user = users.first { attrs["user_id"] = b[user] }
        let (reason,ext) = try reasoning(b); attrs["reasoning"] = reason; attrs["cache"] = try cache(b,mark,index); let extras = ext.merging(.object(b.o.filter { Self.extensions.contains($0.key) })); attrs["extensions"] = extras.empty ? .null : extras
        return try Request(json:["model":model,"messages":arr(messages),"system":system,"tools":arr(tools(b["tools"])),"config":attrs])
    }
}
extension ProviderLM {
    public func requestFromOpenAIChat(_ body: JSONValue) throws -> Request { if dialect != "openai-chat" { try unsupported("Chat Completions ingestion on this dialect") }; var ingest = ChatIngest(lm:self); return try ingest.read(body) }
}
public func requestFromOpenAIChat(_ body: JSONValue, compat: JSONValue = .null) throws -> Request { let lm = try OpenAIChatLM(baseURL:"http://localhost/v1",compat:compat,env:[:]); return try lm.requestFromOpenAIChat(body) }
