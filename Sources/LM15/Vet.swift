import Foundation

/// NDJSON protocol dispatch. All transformations call the package's public surface.
public enum Vet {
    public static func handle(_ msg: JSONValue) async throws -> JSONValue {
        switch msg["op"].s {
        case "resolve_model":
            let registry = msg.has("catalog") ? try ModelRegistry(msg["catalog"].a.map { try ModelInfo(json:$0) }) : nil
            return try resolveModel(msg["model"].s,registry:registry,env:msg["env"].o.mapValues(\.s)).toJSON()
        case "replay_stream":
            let lm = try ProviderLM(provider:msg["provider"].s,env:[:]), request = try Request(json:msg["canonical_request"])
            let events = try lm.replayStream(request,body:try checkedBase64(msg["body_b64"].s))
            do { return ["events":arr(events.map { $0.toJSON() }),"canonical_response":try materializeResponse(events,request:request).toJSON()] }
            catch let e as StreamAssemblyError { throw StreamAssemblyError(e.message,metadata:e.metadata.with("events",arr(events.map { $0.toJSON() }))) }
        case "parse_response":
            let lm = try ProviderLM(provider:msg["provider"].s,env:[:])
            let response = try lm.parseResponse(Request(json:msg["canonical_request"]),response:HTTPResponse(status:msg["status"].or(200).i,body:try checkedBase64(msg["body_b64"].s)))
            var result: J = ["canonical_response":response.toJSON()]
            if response.rawValue["provider_data"].has("_lm15_unmapped") { result["unmapped"] = response.rawValue["provider_data"]["_lm15_unmapped"] }
            return result
        case "build_request":
            let credential = msg["credential"].present ? try Credential(json:msg["credential"]) : nil
            let now = parseDate(msg["now"].s) ?? Date()
            let lm = try ProviderLM(provider:msg["provider"].s,apiKey:msg["api_key"].isNull ? nil : msg["api_key"].s,credential:credential,baseURL:msg["base_url"].isNull ? nil : msg["base_url"].s,settings:msg["settings"].or([:]),env:[:],clock:{ now },accountID:msg["provider"] == "openai-codex" ? "test-account" : nil)
            return try await lm.buildRequest(Request(json:msg["canonical_request"]),stream:msg["stream"].b).normalized()
        case "normalize_error":
            let lm = try ProviderLM(provider:msg["provider"].s,apiKey:"vet-parse-only",settings:msg["settings"].or([:]),env:[:])
            let e = lm.normalizeError(status:msg["status"].i,body:msg["body_text"].s)
            return ["class":j(e.className),"code":j(e.code),"provider_code":e.metadata["provider_code"],"message":j(e.message)]
        case "sigv4_sign":
            let r = msg["request"]; guard let now = parseDate(msg["now"].s) else { throw ValueError("invalid signing timestamp") }
            return try SigV4.sign(method:r["method"].s,url:r["url"].s,headers:r["headers"].or([:]),body:Data(r["body"].or("").s.utf8),credential:AwsCredentials(json:msg["credential"]),region:msg["region"].s,service:msg["service"].s,now:now)
        case "serde_roundtrip": return ["value":try Canonical.normalize(msg["kind"].s,msg["value"])]
        case "validate": return ["ok":true,"normalized":try Canonical.normalize(msg["kind"].s,msg["value"])]
        case "surface_dump": return Surface.dump()
        case "capabilities": return ["language":"swift","ops":arr(["batch_op_build", "batch_op_parse", "build_models_request", "build_request", "cache_op_build", "cache_op_parse", "capabilities", "explain_auth", "file_op_build", "file_op_parse", "generation_build", "generation_parse", "ingest_openai_chat", "normalize_error", "parse_models_response", "parse_response", "replay_live", "replay_stream", "resolve_model", "serde_roundtrip", "sigv4_sign", "surface_dump", "token_exchange_build", "token_exchange_parse", "validate", "video_op_build", "video_op_parse"].map(j)),"impl_version":"0.1.0"]
        default: return try await endpoint(msg)
        }
    }
}

private func checkedBase64(_ text: String) throws -> Data { guard let data = Data(base64Encoded:text) else { throw ValueError("invalid body_b64") }; return data }
