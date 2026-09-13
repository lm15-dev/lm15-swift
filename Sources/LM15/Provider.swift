import Foundation

public typealias CredentialProvider = @Sendable () async throws -> Credential
public typealias Clock = @Sendable () -> Date

public struct AccessPolicy: Sendable, Equatable {
    public let value: JSONValue
    public init(json: JSONValue) throws { guard json["supports"].isObject, json["credential_policy"].isString else { throw ValueError("invalid access policy") }; value = json }
    public func supports(_ feature: String) -> Bool { value["supports"][feature].b }
}
open class ProviderLM: @unchecked Sendable {
    public let provider: String, dialect: String, baseURL: String
    public let settings: JSONValue, access: AccessPolicy
    public let transport: any HTTPTransport
    let definition: J, compat: J, env: [String:String], clock: Clock, explicitURL: String?, accountID: String?, credentialsPath: String?
    let suppliedCredential: CredentialProvider?
    let cloudCache = CredentialCache()
    public init(provider: String = "openai", apiKey: String? = nil, credential: Credential? = nil, credentialProvider: CredentialProvider? = nil, baseURL: String? = nil, settings: JSONValue = [:], compat: JSONValue = .null, env: [String:String] = Environment.current, credentialsPath: String? = nil, clock: @escaping Clock = { Date() }, transport: any HTTPTransport = URLSessionTransport(), accountID: String? = nil) throws {
        let id = provider.replacingOccurrences(of:"_",with:"-"); let def = Tables.data["providers"][id]
        guard def.present else { throw ValueError("unknown provider: \(provider)") }
        self.provider = id; definition = def; dialect = def["dialect"].s; access = try AccessPolicy(json:def["access"])
        self.compat = compat; self.env = env; self.credentialsPath = credentialsPath; self.clock = clock; self.transport = transport; self.accountID = accountID; explicitURL = baseURL
        if let credentialProvider { suppliedCredential = credentialProvider }
        else if let credential { suppliedCredential = { credential } }
        else if let apiKey { suppliedCredential = { guard !apiKey.isEmpty else { throw NotConfiguredError("explicit credential is empty") }; return .apiKey(try ApiKey(value:apiKey)) } }
        else { suppliedCredential = nil }
        let defaults = ["openai-chat":"https://api.openai.com/v1","openai-responses":"https://api.openai.com/v1","anthropic":"https://api.anthropic.com/v1","gemini":"https://generativelanguage.googleapis.com/v1beta"]
        var url = baseURL ?? (def["access"]["base_url"].isNull ? defaults[dialect]! : def["access"]["base_url"].s)
        if compat.isString && baseURL == nil {
            let key = Self.compatKey(dialect); let name = Self.presetName(compat.s)
            guard Tables.data["compat"][key + "_PRESETS"].has(name) else { throw ValueError("unknown compat preset") }
            let presetURL = Tables.data["compat"][key + "_PRESET_BASE_URLS"][name]
            guard presetURL.present else { throw NotConfiguredError("compat preset requires an explicit baseURL") }; url = presetURL.s
        }
        let resolved: (url: String?, settings: J)
        do { resolved = try Self.resolveHost(provider:id,access:def["access"],settings:settings,env:env,explicitURL:baseURL) }
        catch is NotConfiguredError { resolved = (nil,settings) }
        self.settings = resolved.settings
        self.baseURL = (resolved.url ?? url).replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression)
    }
    func unsupported(_ feature: String) throws -> Never { throw UnsupportedFeatureError("\(provider): \(feature) is not supported",metadata:["provider":j(provider)]) }
    func support(_ feature: String) throws { if !access.supports(feature) { try unsupported(feature) } }
    public func credential() async throws -> Credential {
        if let suppliedCredential { return try await suppliedCredential() }
        return try await resolveCredential()
    }
    static func compatKey(_ dialect: String) -> String { ["openai-chat":"OPENAI_CHAT","openai-responses":"OPENAI_RESPONSES","anthropic":"ANTHROPIC"][dialect] ?? "" }
    static func presetName(_ name: String) -> String { let n = name.lowercased().replacingOccurrences(of:#"[- .]"#,with:"_",options:.regularExpression); return Tables.data["compat_aliases"][n].or(j(n)).s }
    public func compatibility(for request: Request) throws -> JSONValue { try compatible(request.rawValue) }
    func compatible(_ r: J) throws -> J {
        let key = Self.compatKey(dialect); if key.isEmpty { return [:] }
        let kind = ["openai-chat":"OpenAIChat","openai-responses":"OpenAIResponses","anthropic":"Anthropic"][dialect]!
        var defaults = Tables.data["compat_defaults"]["Resolved\(kind)Compat"]
        let fallback: J = provider == "xai" ? "xai" : definition["compat"].or(dialect == "anthropic" ? "anthropic" : "openai")
        let name = Self.presetName(compat.isString ? compat.s : fallback.s)
        let raw = Tables.data["compat"][key + "_PRESETS"][name]
        guard raw.present else { throw ValueError("unknown compat preset: \(name)") }
        if compat.isObject && !Set(compat.o.keys).isSubset(of:Set(raw.o.keys)) { throw ValueError("unknown compat fields") }
        let partial = raw.merging(compat.compact())
        for (k,v) in partial.o where k != "model_overrides" && v.present && v != "auto" { defaults[k] = v }
        for pair in partial["model_overrides"].a where r["model"].s.hasPrefix(pair[0].s) { for (k,v) in pair[1].o where v.present && v != "auto" { defaults[k] = v }; break }
        if dialect == "openai-responses" {
            let ext = r["config"]["extensions"], standard = Tables.data["compat_defaults"]["ResolvedOpenAIResponsesCompat"]
            let override = ext["openai_responses_compat"].or(ext["openai_compat"]).or(ext["compat"]["openai_responses"]).or(ext["compat"]["openai"])
            for (k,v) in override.o where standard.has(k) && v.present { defaults[k] = k == "extensions" ? defaults[k].merging(v) : v == "auto" ? standard[k] : v }
        }; return defaults
    }
    func extensions(_ payload: J, _ config: J, _ compat: J = [:]) -> J { payload.merging(compat["extensions"]).merging(config["extensions"].without(["prompt_caching","cache","compat","openai_responses_compat","openai_compat","openai_chat_compat"])) }
    func emit(_ method: String, _ path: String, payload: J = .null, params: J = [:], headers: J = [:], body: Data? = nil, request: J = .null) async throws -> TransportRequest {
        _ = try Self.resolveHost(provider:provider,access:access.value,settings:settings,env:env,explicitURL:explicitURL)
        var url = path.hasPrefix("http://") || path.hasPrefix("https://") ? path : baseURL + "/" + (path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var h = J.object(headers.o.reduce(into:[:]) { $0[$1.key.lowercased()] = $1.value }), p = params, payload = payload
        if payload.present && !h.has("content-type") { h["content-type"] = "application/json" }
        for pair in access.value["headers"].a {
            let k = pair[0].s.lowercased(), v = pair[1]
            h[k] = k == "anthropic-beta" && h[k].present ? j((h[k].s + "," + v.s).components(separatedBy:",").reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator:",")) : v
        }
        let c = try await credential(), schemes = access.value["auth_scheme"].a.map(\.s)
        switch c {
        case .apiKey(let key):
            switch schemes.first(where: { $0 != "sigv4" }) {
            case "bearer": h["authorization"] = j("Bearer \(key.value)")
            case "x-api-key","api-key","x-goog-api-key": let scheme = schemes.first(where: { $0 != "sigv4" })!; h[dialect == "gemini" && scheme == "x-api-key" ? "x-goog-api-key" : scheme] = j(key.value)
            case "query-key": p["key"] = j(key.value)
            default: throw NotConfiguredError("API key is incompatible with \(provider)")
            }
        case .bearerToken(let token):
            if schemes.contains("bearer") { h["authorization"] = j("Bearer \(token.value)") }
            else if schemes.contains("x-api-key") { h[dialect == "gemini" ? "x-goog-api-key" : "x-api-key"] = j(token.value) }
            else { throw NotConfiguredError("bearer credential is incompatible with \(provider)") }
        case .aws: if !schemes.contains("sigv4") { throw NotConfiguredError("AWS credentials incompatible with \(provider)") }
        }
        if provider == "openai-codex" {
            var account = accountID
            if account == nil, case .bearerToken(let token) = c { account = Auth.accountID(token.value) }
            if account == nil && suppliedCredential == nil { account = try? Auth.loadOAuth(provider:provider,path:credentialsPath,env:env).accountID }
            if let account { h["chatgpt-account-id"] = j(account) }
        }
        (url,payload,h) = try finishHostRequest(url,payload,h,request)
        var wire = try TransportRequest(method:method,url:url,headers:h,body:body ?? (payload.isNull ? Data() : payload.jsonData()),params:p)
        if case .aws(let aws) = c {
            let host = access.value["host"]
            guard host["sigv4_service"].present else { throw NotConfiguredError("AWS credentials need a SigV4 host") }
            let signed = try SigV4.sign(method:wire.method,url:wire.url,headers:wire.headers,body:wire.body,credential:aws,region:settings["region"].s,service:host["sigv4_service"].s,now:clock())
            wire = try TransportRequest(method:wire.method,url:wire.url,headers:signed["headers"],body:wire.body)
        }; return wire
    }
    public func normalizeError(status: Int, body: String, headers: JSONValue = [:]) -> LM15Error {
        var message = String(body.trimmingCharacters(in:.whitespacesAndNewlines).prefix(500)), pc: J = nil, code: String?, rid: J = nil
        if let data = try? J.parse(body) {
            if provider == "openai-codex" && data["detail"].isString { message = data["detail"].s; if modelError(message) { code = "unsupported_model" } }
            else {
                var e = data["error"].or([:]); if dialect == "anthropic" && !e.isString && e.empty { e = data }
                if provider == "xai" && e.isString { e = ["message":e,"code":data["code"]] }
                message = e.isObject ? e["message"].or("").stringValue : e.stringValue
                if dialect == "anthropic" {
                    pc = e["type"].or(e["code"]); rid = data["request_id"]
                    code = contextError(message) ? "context_length" : pc == "DeploymentNotFound" || ["not_found_error","resource_not_found_error"].contains(pc.s) && modelError(message) ? "unsupported_model" : Self.anthropicErrors[pc.s]
                } else if dialect == "gemini" {
                    pc = e["status"]; code = contextError(message) ? "context_length" : pc == "NOT_FOUND" && modelError(message) ? "unsupported_model" : Self.geminiErrors[pc.s]
                } else {
                    let c = e["code"], t = e["type"]; pc = c.or(t)
                    if c == "context_length_exceeded" { code = "context_length" }
                    else if Self.modelErrors.contains(c.s) || status == 404 && modelError([message,c.s,t.s].joined(separator:" ")) { code = "unsupported_model" }
                    else if ["insufficient_quota","1113"].contains(c.stringValue) || ["insufficient_quota","exceeded_current_quota_error"].contains(t.s) { code = "billing" }
                    else if c == "invalid_api_key" || t == "authentication_error" { code = "auth" }
                    else if c == "rate_limit_exceeded" || t == "rate_limit_error" { code = "rate_limit" }
                }
                if code == nil && pc.present && !message.contains(pc.stringValue) { message += " (\(pc.stringValue))" }
            }
        }
        if code == nil { code = [401:"auth",403:"auth",402:"billing",429:"rate_limit",408:"timeout",504:"timeout",400:"invalid_request",404:"invalid_request",409:"invalid_request",413:"invalid_request",422:"invalid_request"][status] ?? ((500...599).contains(status) ? "server" : "provider") }
        if message.isEmpty { message = "HTTP \(status)" }
        let h = J.object(headers.o.reduce(into:[:]) { $0[$1.key.lowercased()] = $1.value })
        if rid.isNull { rid = ["x-request-id","request-id","x-amzn-requestid","x-amz-request-id","x-ms-request-id"].map { h[$0] }.first(where: \.present) ?? .null }
        var meta: J = ["provider":j(provider),"status":j(status),"provider_code":pc.isNull ? .null : j(pc.stringValue),"request_id":rid]
        if let seconds = Double(h["retry-after"].s), seconds >= 0, seconds.isFinite { meta["retry_after"] = .number(seconds) }
        return errorFromCode(code!,message,meta)
    }
    func modelError(_ text: String) -> Bool { let s = text.lowercased(); return s.contains("model") && ["not found","does not exist","not exist","not supported","unsupported","not available","unknown"].contains(where:s.contains) }
    func contextError(_ text: String) -> Bool { let s = text.lowercased(); return s.contains("token") && (s.contains("limit") || s.contains("exceed")) || s.contains("context length") || (dialect == "gemini" ? s.contains("too long") : ["prompt is too long","too many tokens","context window"].contains(where:s.contains)) }
    func errorDetail(_ pc: J, _ message: String) -> J {
        let code: String?
        if dialect == "anthropic" { code = contextError(message) ? "context_length" : pc == "not_found_error" && modelError(message) ? "unsupported_model" : Self.anthropicErrors[pc.s] }
        else if dialect == "gemini" { code = contextError(message) ? "context_length" : pc == "NOT_FOUND" && modelError(message) ? "unsupported_model" : Self.geminiErrors[pc.s] }
        else { code = Self.openaiErrors[pc.s] }
        return ["code":j(code ?? "provider"),"message":j(message.isEmpty ? (pc.empty ? "provider error" : pc.s) : message),"provider_code":pc.empty ? "provider" : pc]
    }
    static let modelErrors = ["model_not_found","model_not_available","unsupported_model","DeploymentNotFound"]
    static let anthropicErrors = ["authentication_error":"auth","permission_error":"auth","billing_error":"billing","rate_limit_error":"rate_limit","request_too_large":"invalid_request","not_found_error":"invalid_request","resource_not_found_error":"invalid_request","DeploymentNotFound":"unsupported_model","invalid_authentication_error":"auth","invalid_request_error":"invalid_request","api_error":"server","overloaded_error":"server","timeout_error":"timeout"]
    static let geminiErrors = ["INVALID_ARGUMENT":"invalid_request","FAILED_PRECONDITION":"billing","PERMISSION_DENIED":"auth","UNAUTHENTICATED":"auth","NOT_FOUND":"invalid_request","RESOURCE_EXHAUSTED":"rate_limit","INTERNAL":"server","UNAVAILABLE":"server","DEADLINE_EXCEEDED":"timeout"]
    static let openaiErrors: [String:String] = {
        var d = ["context_length_exceeded":"context_length","invalid_api_key":"auth","insufficient_quota":"billing","1113":"billing","exceeded_current_quota_error":"billing","authentication_error":"auth","rate_limit_error":"rate_limit","server_error":"server","rate_limit_exceeded":"rate_limit","invalid_prompt":"invalid_request","vector_store_timeout":"timeout"]
        for k in modelErrors { d[k] = "unsupported_model" }
        for k in ["invalid_image","invalid_image_format","invalid_base64_image","invalid_image_url","image_too_large","image_too_small","image_parse_error","image_content_policy_violation","invalid_image_mode","image_file_too_large","unsupported_image_media_type","empty_image_file","failed_to_download_image","image_file_not_found"] { d[k] = "invalid_request" }; return d
    }()
}
func pathID(_ text: String, resource: Bool = false) -> String { text.utf8.map { b in (b >= 65 && b <= 90 || b >= 97 && b <= 122 || b >= 48 && b <= 57 || [45,46,95,126].contains(b) || resource && b == 47) ? String(UnicodeScalar(b)) : String(format:"%%%02X",b) }.joined() }
func partsText(_ parts: [J]) throws -> String {
    try parts.compactMap { p -> String? in
        let type = p["type"].s
        if Canonical.media.contains(type) { throw UnsupportedFeatureError("\(type) cannot reach a text-only field") }
        if ["text","thinking","refusal"].contains(type) { return p["text"].s }
        if type == "citation" { return [p["title"],p["url"],p["text"]].filter { !$0.empty }.map(\.s).joined(separator:" — ") }; return nil
    }.joined(separator:"\n")
}
func mediaBase64(_ p: J) throws -> String { if p["data"].present { return p["data"].s }; return try Data(contentsOf:URL(fileURLWithPath:p["path"].s)).base64EncodedString() }
func mediaURI(_ p: J) throws -> String { "data:\(p["media_type"].s);base64,\(try mediaBase64(p))" }
func parseObject(_ value: J) -> J { if value.isObject { return value }; guard value.isString && !value.empty else { return [:] }; guard let parsed = try? J.parse(value.s) else { return ["partial_json":value] }; return parsed.isObject ? parsed : ["value":parsed] }
func continuationData(_ value: J, _ provider: String, _ kind: String) -> J { value["continuation"].a.first { $0["provider"].s == provider && $0["kind"].s == kind }?["data"] ?? .null }
