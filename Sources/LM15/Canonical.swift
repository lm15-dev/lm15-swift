import Foundation

enum Tables {
    static func load(_ name: String) -> J {
        // These resources are versioned declarations, never conformance fixtures.
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url), let value = try? J.parse(data) else { preconditionFailure("Missing LM15 declaration resource: \(name)") }
        return value
    }
    static let schema = load("schema"), vocab = load("vocab"), data = load("tables")
}
public protocol CanonicalValue: Sendable, Equatable, Codable {
    static var canonicalName: String { get }
    var rawValue: JSONValue { get }
    init(json: JSONValue) throws
}
extension CanonicalValue {
    public func toJSON(includeProviderData: Bool = false) -> JSONValue { Canonical.serialize(Self.canonicalName, rawValue, includeProviderData: includeProviderData) }
    public func toJSONString(includeProviderData: Bool = false) throws -> String { try toJSON(includeProviderData: includeProviderData).jsonString() }
    public static func fromJSON(_ text: String) throws -> Self { try Self(json: .parse(text)) }
    public init(from decoder: any Decoder) throws { try self.init(json: JSONValue(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try toJSON().encode(to: encoder) }
}
public enum Canonical {
    static let kinds: [String:String] = ["part":"Part","message":"Message","tool":"Tool","tool_choice":"ToolChoice","reasoning":"Reasoning","config":"Config","cache_config":"CacheConfig","cache_info":"CacheInfo","cache_page":"CachePage","cached_prefix":"CachedPrefix","token_logprob":"TokenLogprob","continuation_state":"ContinuationState","error_detail":"ErrorDetail","delta":"Delta","usage":"Usage","credential":"Credential","stream_event":"StreamEvent","request":"Request","response":"Response","model_info":"ModelInfo","batch_request":"BatchRequest","batch_job":"BatchJobInfo","batch_entry":"BatchEntry","file_upload_request":"FileUploadRequest","file_info":"FileInfo","file_page":"FilePage","image_generation_request":"ImageGenerationRequest","image_generation_response":"ImageGenerationResponse","speech_generation_request":"SpeechGenerationRequest","speech_generation_response":"SpeechGenerationResponse","video_generation_request":"VideoGenerationRequest","video_job":"VideoJobInfo","audio_format":"AudioFormat","live_config":"LiveConfig","live_client_event":"LiveClientEvent","live_server_event":"LiveServerEvent"]
    static let media = ["image","audio","video","document","binary"]
    static let sums: [String:[String]] = [
        "Part":["Text","Image","Audio","Video","Document","Binary","ToolCall","ToolResult","Thinking","Refusal","Citation"].map { $0 + "Part" },
        "PromptPart":["TextPart","ImagePart","AudioPart","VideoPart","DocumentPart","BinaryPart"],
        "ToolResultContentPart":["TextPart","ImagePart","AudioPart","VideoPart","DocumentPart","BinaryPart","CitationPart"],
        "Delta":["TextDelta","ThinkingDelta","AudioDelta","ImageDelta","ToolCallDelta","CitationDelta","ContinuationDelta"],
        "Tool":["FunctionTool","BuiltinTool"], "StreamEvent":["StreamStartEvent","StreamDeltaEvent","StreamEndEvent","StreamErrorEvent"],
        "Credential":["ApiKey","BearerToken","AwsCredentials"],
        "LiveClientEvent":Tables.schema.o.keys.filter { $0.hasPrefix("LiveClient") }.sorted(),
        "LiveServerEvent":Tables.schema.o.keys.filter { $0.hasPrefix("LiveServer") }.sorted()
    ]
    static func concrete(_ kind: String, _ value: J) throws -> String {
        let name = kinds[kind] ?? kind
        guard value.isObject else { throw TypeError("\(name) must be an object") }
        guard let variants = sums[name] else { guard Tables.schema.has(name) else { throw ValueError("unknown kind \(kind)") }; return name }
        let key = name == "Credential" ? "kind" : "type"
        let tag = name == "Tool" ? (value[key] == "builtin" ? J.string("builtin") : J.string("function")) : value[key]
        guard let found = variants.first(where: { Tables.schema[$0][key]["default"] == tag }) else { throw ValueError("unknown \(name) discriminator \(tag.s)") }; return found
    }
    public static func normalize(_ kind: String, _ value: JSONValue) throws -> JSONValue { let name = try concrete(kind, value); return serialize(name, try record(name, value)) }
    static func record(_ kind: String, _ input: J) throws -> J {
        let n = try concrete(kind, input), fields = Tables.schema[n]; var d = input
        if n == "Reasoning" {
            d["effort"] = input["effort"].or(input["enabled"] == false ? "off" : "medium")
            if d["effort"] == "adaptive" { d["effort"] = "medium" }; d["thinking_budget"] = input["thinking_budget"].or(input["budget"])
            if d["effort"] == "off" { d = ["effort":"off"] }
        }
        if fields.has("text") && !d.has("text") && (n.hasSuffix("Part") || n.hasSuffix("Delta") || n.contains("TextEvent")) { d["text"] = "" }
        if n == "ErrorDetail" && !d.has("message") { d["message"] = "" }
        if ["ToolCallPart","LiveServerToolCallEvent"].contains(n) && !d.has("input") { d["input"] = [:] }
        if n == "ToolCallDelta" && !d.has("input") { d["input"] = "" }
        if n == "Message" { d["parts"] = arr(input["parts"].a.map { $0.isObject ? $0 : ["type":"text","text":j($0.stringValue)] }) }
        if n == "ToolResultPart" {
            let c = input["content"]
            d["content"] = c.isString ? (c.empty ? [] : [["type":"text","text":c]]) : arr(c.a.map { $0.isObject ? $0 : ["type":"text","text":j($0.stringValue)] })
        }
        let fallback: [String:[String:J]] = ["Response":["usage":[:]],"StreamEndEvent":["usage":nil],"ModelInfo":["origin":[:],"inference":nil],"InferenceModelInfo":["pricing":nil],"LiveConfig":["input_format":nil,"output_format":nil],"CachedPrefix":["resource":nil]]
        for (key,v) in fallback[n] ?? [:] where !d[key].isObject { d[key] = v }
        if n == "Response" && !d.has("id") { d["id"] = .null }
        if ["ImageGenerationResponse","SpeechGenerationResponse","LiveServerTurnEndEvent","LiveServerUsageEvent"].contains(n) && d["usage"].isNull { d["usage"] = [:] }
        var out: J = [:]
        for (field, desc) in fields.o {
            let v: J
            if !desc["init"].b { v = desc["default"] }
            else if d.has(field) { v = d[field] }
            else if desc.has("default") { v = desc["default"] }
            else { throw ValueError("missing \(n).\(field)") }
            out[field] = try convert(n, field, desc["type"].s, v)
        }
        try validate(n, &out); return out
    }
    static func convert(_ n: String, _ field: String, _ declaration: String, _ v: J) throws -> J {
        let optional = declaration.hasSuffix(" | None"), type = optional ? String(declaration.dropLast(7)) : declaration
        if v.isNull && optional { return .null }
        if field == "system" {
            if v.isNull { return .null }; if v.isString { guard !v.empty else { throw ValueError("system cannot be empty") }; return v }
            let a = v.isArray ? v.a : [v]; guard !a.isEmpty else { throw ValueError("system cannot be empty") }; return arr(try a.map { try record("PromptPart", $0.isString ? ["type":"text","text":$0] : $0) })
        }
        if type.hasPrefix("tuple[") {
            let element = String(type.dropFirst(6).dropLast(6)); let a = field == "continuation" && v.isNull ? [] : v.isArray ? v.a : [v]
            return arr(try a.map { try convert(n, field, element, $0) })
        }
        if Tables.schema.has(type) || sums[type] != nil { return try record(type, v) }
        let words = Tables.vocab[type].a
        if !words.isEmpty || type.hasPrefix("Literal[") {
            let allowed = !words.isEmpty ? words.map(\.s) : type.split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
            guard allowed.contains(v.s) && v.isString else { throw ValueError("unsupported \(field)") }; return v
        }
        switch type {
        case "int","float":
            guard v.isNumber else { throw TypeError("\(field) must be numeric") }; guard v.d.isFinite else { throw ValueError("\(field) must be finite") }
            if type == "int" { if case .int = v { return v }; guard v.d.rounded(.towardZero) == v.d && v.d >= Double(Int64.min) && v.d < Double(Int64.max) else { throw ValueError("\(field) must be an integer") }; return .int(Int64(v.d)) }; return .number(v.d)
        case "str","Path","ContinuationKind":
            guard v.isString else { throw TypeError("\(field) must be a string") }
            let allowEmpty = ["text","input","input_delta","token","message","description"].contains(field) && n != "RefusalPart"
            guard allowEmpty || !v.empty else { throw ValueError("\(field) cannot be empty") }; return v
        case "bool": guard case .bool = v else { throw TypeError("\(field) must be boolean") }; return v
        case "JsonObject","ProviderData","Extensions": guard v.isObject else { throw TypeError("\(field) must be an object") }; _ = try v.jsonString(); return field == "extensions" && v.empty ? .null : v
        case "bytes": guard v.isString, Data(base64Encoded: v.s) != nil else { throw ValueError("invalid base64 bytes") }; return v
        case "datetime": guard let date = parseDate(v.s) else { throw ValueError("invalid RFC3339 date") }; return j(isoDate(date))
        default: throw TypeError("unsupported declaration \(type)")
        }
    }
    static func validate(_ n: String, _ a: inout J) throws {
        for (k,v) in a.o where !v.isNull {
            if (["part_index","prefix_until_index","logprobs","index","size_bytes","tokens","progress","token_id","context_window","max_output_tokens"].contains(k) || n == "Usage" && k.hasSuffix("tokens")) && v.isNumber && v.d < 0 { throw ValueError("\(k) must be nonnegative") }
            if ["max_tokens","top_k","thinking_budget","sample_rate","channels","seconds"].contains(k) && v.d <= 0 { throw ValueError("\(k) must be positive") }
        }
        if n == "Config" {
            if a["temperature"].present && a["temperature"].d < 0 { throw ValueError("temperature must be nonnegative") }
            if a["top_p"].present && !(0...1).contains(a["top_p"].d) { throw ValueError("top_p out of range") }
            let f = a["response_format"]
            if f.present {
                let keys = Set(f.o.keys)
                let simple = f["type"] == "json_object" && keys == ["type"]
                let schema = f["type"] == "json_schema" && f["schema"].isObject && keys.isSubset(of: ["type","schema","name","strict"]) && (!f.has("name") || f["name"].isString) && (!f.has("strict") || f["strict"] == true || f["strict"] == false)
                if !simple && !schema { throw ValueError("unsupported response_format") }
            }
        }
        if media.contains(a["type"].s) && n.hasSuffix("Part") {
            guard ["data","url","file_id","path"].filter({ a[$0].present }).count == 1 else { throw ValueError("media requires exactly one source") }
            if a["data"].present { a["data"] = j(try base64Data(a["data"].s)) }
        }
        if ["ImageDelta","AudioDelta"].contains(n) && ["data","url","file_id"].filter({ a[$0].present }).count > 1 { throw ValueError("media delta has conflicting sources") }
        if ["CitationPart","CitationDelta"].contains(n) && !["text","url","title"].contains(where: { !a[$0].empty }) { throw ValueError("citation needs text, title or URL") }
        if ["ToolResultPart","LiveClientToolResultEvent"].contains(n) && a["content"].empty { throw ValueError("tool result content cannot be empty") }
        if n == "Message" {
            guard !a["parts"].empty else { throw ValueError("message cannot be empty") }
            let allowed = a["role"] == "tool" ? ["tool_result"] : a["role"] == "assistant" ? ["text","image","audio","video","document","binary","thinking","refusal","citation","tool_call"] : ["text","image","audio","video","document","binary"]
            guard a["parts"].a.allSatisfy({ allowed.contains($0["type"].s) }) else { throw ValueError("parts incompatible with role") }
        }
        if n == "CacheConfig" {
            if a["mode"] == "off" && a.o.contains(where: { $0.key != "mode" && $0.value.present }) { throw ValueError("off cache has settings") }
            if a["prefix"].present && a["prefix_until_index"].present { throw ValueError("conflicting cache prefix choices") }
        }
        if n == "ToolChoice" && a["mode"] == "none" && (!a["allowed"].empty || a["parallel"].present) { throw ValueError("none tool choice has settings") }
        if n == "Usage" && a["total_tokens"].isNull && a["input_tokens"].present && a["output_tokens"].present { let (sum,overflow) = a["input_tokens"].i.addingReportingOverflow(a["output_tokens"].i); guard !overflow else { throw ValueError("usage count overflow") }; a["total_tokens"] = j(sum) }
        if ["Request","LiveConfig"].contains(n) {
            let names = a["tools"].a.map { $0["name"].s }; if Set(names).count != names.count { throw ValueError("duplicate tool names") }
            if n == "Request" {
                guard !a["messages"].empty else { throw ValueError("request messages cannot be empty") }
                guard a["config"]["tool_choice"]["allowed"].a.allSatisfy({ names.contains($0.s) }) else { throw ValueError("tool_choice references missing tool") }
            }
        }
        if n == "Response" && a["message"]["role"] != "assistant" { throw ValueError("response must be assistant") }
        if n == "FileUploadRequest" && ["bytes_data","path"].filter({ !a[$0].empty }).count != 1 { throw ValueError("upload requires bytes or path") }
        if n == "BatchRequest" { if a["requests"].empty { throw ValueError("batch cannot be empty") }; if a["model"].isNull { a["model"] = a["requests"][0]["model"] } }
        if n == "BatchEntry" {
            let outcome = a["outcome"].s, response = a["response"].present, error = a["error"].present
            if outcome == "succeeded" && (!response || error) || outcome == "errored" && (!error || response) || ["cancelled","expired"].contains(outcome) && (response || error) { throw ValueError("invalid batch outcome payload") }
        }
        if n == "CachedPrefix" {
            if !serialize("Config",a["prefix"]["config"]).empty { throw ValueError("cached prefix requires default config") }
            if a["resource"].present && a["resource"]["model"] != a["prefix"]["model"] { throw ValueError("cached resource model differs") }
        }
        if n == "LiveClientTurnEvent" && a["parts"].empty { throw ValueError("turn cannot be empty") }
    }
    static func serialize(_ kind: String, _ raw: J, includeProviderData: Bool = false) -> J {
        guard let n = try? concrete(kind, raw) else { return raw }; let fields = Tables.schema[n]
        let required: [String:[String]] = ["TextPart":["type","text"],"ThinkingPart":["type","text"],"RefusalPart":["type","text"],"ToolCallPart":["type","id","name","input"],"ToolResultPart":["type","id","content"],"FunctionTool":["type","name","parameters"],"ContinuationState":["provider","kind","data"],"ContinuationDelta":["type","provider","kind","data"],"Message":["role","parts"],"Request":["model","messages"],"Response":["model","message","finish_reason"],"TokenLogprob":["token","logprob","bytes"],"TopLogprob":["token","logprob","bytes"]]
        var out: J = [:]
        for (k,desc) in fields.o {
            let value = raw[k]; if value.isNull { continue }
            if n == "Response" && k == "provider_data" && !includeProviderData { continue }
            if ["is_error","supports_reasoning"].contains(k) && value == false { continue }
            let v = serializeField(desc["type"].s, value, includeProviderData || n == "BatchEntry" && k == "response")
            if n == "ModelInfo" && k == "origin" && v == ["type":"provider"] { continue }
            let keepEmpty = n.hasSuffix("Delta") || n.hasPrefix("LiveClient") || n.hasPrefix("LiveServer") || (required[n] ?? []).contains(k)
            if !keepEmpty && v.empty || n == "TextDelta" && k == "logprobs" && v.empty { continue }
            out[k] = v
        }; return out
    }
    static func serializeField(_ declaration: String, _ v: J, _ include: Bool) -> J {
        let type = declaration.hasSuffix(" | None") ? String(declaration.dropLast(7)) : declaration
        if type.hasPrefix("str | tuple[") && v.isArray { return arr(v.a.map { serialize("PromptPart",$0,includeProviderData:include) }) }
        if type.hasPrefix("tuple[") { return arr(v.a.map { serializeField(String(type.dropFirst(6).dropLast(6)),$0,include) }) }
        if Tables.schema.has(type) || sums[type] != nil { return serialize(type,v,includeProviderData:include) }; return v
    }
}
func base64Data(_ value: String) throws -> String {
    let tail = value.hasPrefix("data:") && value.contains(";base64,") ? String(value.components(separatedBy:";base64,").dropFirst().joined(separator:";base64,")) : value
    let clean = tail.filter { !$0.isWhitespace }
    guard !clean.isEmpty, clean.utf8.count % 4 == 0, clean.range(of:#"^[A-Za-z0-9+/]*={0,2}$"#,options:.regularExpression) != nil else { throw ValueError("invalid base64 data") }; return clean
}
func parseDate(_ text: String) -> Date? { let f = ISO8601DateFormatter(); if let d = f.date(from:text) { return d }; f.formatOptions.insert(.withFractionalSeconds); return f.date(from:text) }
func isoDate(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
