import Foundation

extension Vet {
    static func adapter(_ m: J, parseOnly: Bool = false) throws -> ProviderLM {
        let credential = m["credential"].present && !parseOnly ? try Credential(json:m["credential"]) : nil, now = parseDate(m["now"].s) ?? Date()
        return try ProviderLM(provider:m["provider"].s,apiKey:parseOnly ? "vet-parse-only" : m["api_key"].isNull ? nil : m["api_key"].s,credential:credential,baseURL:m["base_url"].isNull ? nil : m["base_url"].s,settings:m["settings"].or([:]),env:[:],clock:{ now },accountID:m["provider"] == "openai-codex" ? "test-account" : nil)
    }
    static func body(_ m: J, key: String = "body_b64") throws -> Data { guard let data = Data(base64Encoded:m[key].s) else { throw ValueError("invalid base64 \(key)") }; return data }
    static func response(_ m: J) throws -> HTTPResponse { HTTPResponse(status:m["status"].or(200).i,headers:m["headers"].or([:]),body:try body(m)) }
    static func checkedBody(_ m: J, _ lm: ProviderLM) throws -> Data { let data = try body(m); if m["status"].i >= 400 { throw lm.normalizeError(status:m["status"].i,body:String(decoding:data,as:UTF8.self)) }; return data }
    static func endpoint(_ m: J) async throws -> J {
        switch m["op"].s {
        case "ingest_openai_chat":
            let lm = m["provider"].present ? try adapter(m,parseOnly:true) : try ProviderLM(provider:"openai-chat",baseURL:"http://localhost/v1",compat:m["compat"],env:[:])
            return ["canonical_request":try lm.requestFromOpenAIChat(m["body"]).toJSON()]
        case "replay_live":
            let lm = try adapter(m,parseOnly:true), config = try LiveConfig(json:m["live_config"])
            return ["setup_frames":arr(try lm.liveSetupFrames(config)),"client_frames":arr(try m["client_events"].a.map { arr(try lm.encodeLiveEvent(LiveClientEvent(json:$0),config:config)) }),"events":arr(try m["server_frames_b64"].a.map { arr(try lm.decodeLiveEvent(body(["body_b64":$0])).map { $0.toJSON() }) })]
        case "token_exchange_build": return try CloudTokens.build(provider:m["provider"].s,rung:m["rung"].s,input:m["input"].or(m["credential"]).or([:]),settings:m["settings"].or([:]),now:parseDate(m["now"].s) ?? Date())
        case "token_exchange_parse":
            do { let d = m["body"].present ? m["body"] : try J.parse(body(m)); let c = try CloudTokens.parse(provider:m["provider"].s,rung:m["rung"].s,status:m["status"].or(200).i,body:d,now:parseDate(m["now"].s) ?? Date()); return ["ok":true,"credential":c.toJSON()] }
            catch let e as LM15Error { return ["ok":false,"error":["class":j(e.className),"code":j(e.code)]] }
        case "explain_auth":
            let keys = Dictionary(m["api_keys_providers"].a.map { ($0.s,CredentialSource(stringLiteral:m["sentinel"].s)) },uniquingKeysWith:{ _,b in b })
            let report = try explainAuth(m["provider"].s,env:m["env"].o.mapValues(\.s),apiKeys:keys,credentialsPath:m["credentials_path"].isNull ? nil : m["credentials_path"].s,files:m["files"].isNull ? nil : m["files"].o.mapValues(\.s),settings:m["settings"].or([:]))
            return ["configured":j(report.configured),"steps":arr(report.steps.map { ["kind":j($0.kind),"state":j($0.state)] }),"report_text":j(report.description)]
        case "build_models_request": return try await adapter(m).modelsRequest().normalized()
        case "parse_models_response": let lm = try adapter(m,parseOnly:true); return ["models":arr(try lm.modelsFromBody(checkedBody(m,lm)).map { $0.toJSON() })]
        case "file_op_build":
            let lm = try adapter(m); let wire: TransportRequest
            switch m["file_op"].s {
            case "upload": wire = try await lm.fileUploadRequest(FileUploadRequest(json:m["upload_request"]))
            case "get": wire = try await lm.fileGetRequest(m["file_id"].s)
            case "delete": wire = try await lm.fileDeleteRequest(m["file_id"].s)
            case "download": wire = try await lm.fileDownloadRequest(m["file_id"].s)
            case "list": wire = try await lm.fileListRequest(limit:m["limit"].or(20).i,cursor:m["cursor"].isNull ? nil : m["cursor"].s)
            default: throw ValueError("unknown file operation")
            }; return try wire.normalized()
        case "file_op_parse": let lm = try adapter(m,parseOnly:true), bytes = try checkedBody(m,lm); return m["kind"] == "info" ? ["file":try lm.fileInfoFromBody(bytes).toJSON()] : ["page":try lm.filePageFromListBody(bytes).toJSON()]
        case "cache_op_build":
            let lm = try adapter(m); let wire: TransportRequest
            switch m["cache_op"].s {
            case "create": wire = try await lm.cacheCreateRequest(Request(json:m["prefix_request"]),ttlSeconds:m["ttl_seconds"].isNull ? nil : m["ttl_seconds"].i,label:m["label"].isNull ? nil : m["label"].s)
            case "get": wire = try await lm.cacheGetRequest(m["cache_id"].s)
            case "delete": wire = try await lm.cacheDeleteRequest(m["cache_id"].s)
            case "update": wire = try await lm.cacheUpdateRequest(m["cache_id"].s,ttlSeconds:m["ttl_seconds"].i)
            case "list": wire = try await lm.cacheListRequest(limit:m["limit"].or(20).i,cursor:m["cursor"].isNull ? nil : m["cursor"].s)
            default: throw ValueError("unknown cache operation")
            }; return try wire.normalized()
        case "cache_op_parse": let lm = try adapter(m,parseOnly:true), bytes = try checkedBody(m,lm); return m["kind"] == "info" ? ["cache":try lm.cacheInfoFromBody(bytes).toJSON()] : ["page":try lm.cachePageFromListBody(bytes).toJSON()]
        case "batch_op_build":
            let lm = try adapter(m); var requests: [TransportRequest] = []
            switch m["action"].s {
            case "upload": if let r = try await lm.batchUploadRequest(BatchRequest(json:m["batch_request"])) { requests = [r] }
            case "submit": requests = [try await lm.batchSubmitRequest(BatchRequest(json:m["batch_request"]),uploadBody:m["upload_body"])]
            case "status": requests = [try await lm.batchStatusRequest(m["batch_id"].s)]
            case "cancel": requests = [try await lm.batchCancelRequest(m["batch_id"].s)]
            case "list": requests = [try await lm.batchListRequest(limit:m["limit"].or(20).i)]
            case "result_fetches": requests = try await lm.batchResultFetches(m["status_body"].or([:]))
            default: throw ValueError("unknown batch action")
            }; return ["requests":arr(try requests.map { try $0.normalized() })]
        case "batch_op_parse":
            let lm = try adapter(m,parseOnly:true)
            switch m["kind"].s {
            case "job": return ["job":try lm.batchJobFromBody(checkedBody(m,lm)).toJSON()]
            case "list": return ["jobs":arr(try lm.batchJobsFromListBody(checkedBody(m,lm)).map { $0.toJSON() })]
            case "entries": return ["entries":arr(try lm.batchEntries(m["status_body"].or([:]),fetched:m["fetched_b64"].a.map { try body(["body_b64":$0]) }).map { $0.toJSON() })]
            default: throw ValueError("unknown batch parse kind")
            }
        case "generation_build":
            let lm = try adapter(m), wire = m["kind"] == "image" ? try await lm.imageGenerateRequest(ImageGenerationRequest(json:m["generation_request"])) : try await lm.speechGenerateRequest(SpeechGenerationRequest(json:m["generation_request"]))
            return try wire.normalized()
        case "generation_parse":
            let lm = try adapter(m,parseOnly:true); _ = try checkedBody(m,lm)
            return m["kind"] == "image" ? try lm.imageGenerateFromResponse(ImageGenerationRequest(json:m["generation_request"]),response:response(m)).toJSON() : try lm.speechGenerateFromResponse(SpeechGenerationRequest(json:m["generation_request"]),response:response(m)).toJSON()
        case "video_op_build":
            let lm = try adapter(m), wire: TransportRequest?
            switch m["action"].s {
            case "submit": wire = try await lm.videoSubmitRequest(VideoGenerationRequest(json:m["video_request"]))
            case "status": wire = try await lm.videoStatusRequest(m["video_id"].s)
            case "result_fetch": wire = try await lm.videoResultFetch(m["status_body"])
            case "list": wire = try await lm.videoListRequest(limit:m["limit"].or(20).i,model:m["model"].isNull ? nil : m["model"].s)
            default: throw ValueError("unknown video action")
            }; return ["requests":try wire.map { [try $0.normalized()] } ?? []]
        case "video_op_parse":
            let lm = try adapter(m,parseOnly:true)
            switch m["kind"].s {
            case "job": return ["job":try lm.videoJobFromBody(checkedBody(m,lm),videoID:m["video_id"].isNull ? nil : m["video_id"].s).toJSON()]
            case "list": return ["jobs":arr(try lm.videoJobsFromListBody(checkedBody(m,lm)).map { $0.toJSON() })]
            case "part": let fetched: HTTPResponse? = m["fetched_b64"].isNull ? nil : HTTPResponse(headers:m["headers"].or([:]),body:try body(m,key:"fetched_b64")); return ["part":try lm.videoPart(m["status_body"].or([:]),fetched:fetched).toJSON()]
            default: throw ValueError("unknown video parse kind")
            }
        default: throw UnsupportedFeatureError("unknown operation \(m["op"].s)")
        }
    }
}
