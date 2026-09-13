import Foundation
import Crypto

public enum SigV4 {
    public static func sign(method: String, url: String, headers: JSONValue, body: Data, credential: AwsCredentials, region: String, service: String, now: Date = Date()) throws -> JSONValue {
        guard let scheme = url.range(of:"://") else { throw ValueError("invalid signing URL") }
        let tail = String(url[scheme.upperBound...]), host = String(tail.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        let rest = String(tail.dropFirst(host.count)).components(separatedBy:"#")[0], parts = rest.components(separatedBy:"?")
        let path = parts[0]; var kept: [String] = []
        for s in path.components(separatedBy:"/") { if s == ".." { if !kept.isEmpty { kept.removeLast() } } else if !s.isEmpty && s != "." { kept.append(s) } }
        var normalized = (path.hasPrefix("/") ? "/" : "") + kept.joined(separator:"/") + (path.hasSuffix("/") && !kept.isEmpty ? "/" : "")
        if normalized.isEmpty { normalized = "/" }
        let canonicalPath = normalized.components(separatedBy:"/").map { pathID($0.removingPercentEncoding ?? $0) }.joined(separator:"/")
        let query = parts.count > 1 ? parts[1] : ""
        var pairs: [(String,String)] = []
        for p in query.components(separatedBy:"&") where !p.isEmpty {
            let kv = p.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            let key = pathID(queryDecode(String(kv[0])))
            let value = pathID(queryDecode(kv.count > 1 ? String(kv[1]) : ""))
            pairs.append((key,value))
        }
        pairs.sort { left,right in left.0 == right.0 ? left.1 < right.1 : left.0 < right.0 }
        let canonicalQuery = pairs.map { $0.0 + "=" + $0.1 }.joined(separator:"&")
        var h: J = [:]
        for (key,value) in headers.o where !["authorization","host","x-amz-date","x-amz-security-token"].contains(key.lowercased()) { let str = value.isArray ? value.a.map(\.stringValue).joined(separator:",") : value.stringValue; h[key.lowercased()] = j(str.split(whereSeparator: \.isWhitespace).joined(separator:" ")) }
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT:0); f.dateFormat = "yyyyMMdd"; let date = f.string(from:now); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; let stamp = f.string(from:now)
        h["host"] = j(host); h["x-amz-date"] = j(stamp); if let token = credential.sessionToken { h["x-amz-security-token"] = j(token) }
        let keys = h.o.keys.sorted(), signed = keys.joined(separator:";")
        let canonical = [method.uppercased(),canonicalPath,canonicalQuery,keys.map { $0+":"+h[$0].s+"\n" }.joined(),signed,sha256(body)].joined(separator:"\n")
        let scope = "\(date)/\(region)/\(service)/aws4_request", toSign = ["AWS4-HMAC-SHA256",stamp,scope,sha256(Data(canonical.utf8))].joined(separator:"\n")
        var key = Data("AWS4\(credential.secretAccessKey)".utf8)
        for s in [date,region,service,"aws4_request"] { key = Data(HMAC<SHA256>.authenticationCode(for:Data(s.utf8),using:SymmetricKey(data:key))) }
        let signature = Data(HMAC<SHA256>.authenticationCode(for:Data(toSign.utf8),using:SymmetricKey(data:key))).hex
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credential.accessKeyId)/\(scope), SignedHeaders=\(signed), Signature=\(signature)"
        h["authorization"] = j(authorization)
        return ["canonical_request":j(canonical),"string_to_sign":j(toSign),"authorization":j(authorization),"headers":h]
    }
}
func sha256(_ data: Data) -> String { Data(SHA256.hash(data:data)).hex }
extension Data { var hex: String { map { String(format:"%02x",$0) }.joined() } }
extension ProviderLM {
    static func resolveHost(provider: String, access: J, settings: J, env: [String:String], explicitURL: String?) throws -> (url: String?, settings: J) {
        let host = access["host"]; if host.isNull { return (nil,settings) }
        var s = try CloudChain(provider:provider,env:env,settings:settings).resolveSettings()
        let known = Set(host["settings"].a.map { $0["name"].s })
        guard Set(s.o.keys).isSubset(of:known) else { throw ValueError("unknown host settings") }
        for setting in host["settings"].a {
            let name = setting["name"].s
            if s[name].isNull { for key in setting["env"].a.map(\.s) { if let value = env[key], !value.isEmpty { s[name] = j(value); break } } }
            s[name] = s[name].or(setting["default"])
            guard !s[name].empty else { throw NotConfiguredError("\(provider): setting \(name) is required") }
        }
        for k in ["region","resource","location"] where s[k].present { guard s[k].s.range(of:#"^[A-Za-z0-9-]+$"#,options:.regularExpression) != nil else { throw NotConfiguredError("\(k) must be a DNS label") } }
        var v = s
        if v["project"].present { v["project"] = j(pathID(v["project"].s)) }
        if v["location"].present { let l = v["location"].s; v["location_host"] = j(l == "global" ? "aiplatform.googleapis.com" : ["us","eu"].contains(l) ? "aiplatform.\(l).rep.googleapis.com" : "\(l)-aiplatform.googleapis.com") }
        var url = host["base_url"].s
        for (k,value) in v.o { url = url.replacingOccurrences(of:"{\(k)}",with:value.s) }
        return (explicitURL ?? url,s)
    }
    func finishHostRequest(_ inputURL: String, _ inputPayload: J, _ inputHeaders: J, _ request: J) throws -> (String,J,J) {
        let h = access.value["host"]; if h.isNull { return (inputURL,inputPayload,inputHeaders) }
        var url = inputURL, payload = inputPayload, headers = inputHeaders
        let endpoint = ["anthropic":"messages","gemini":"generateContent","openai-chat":"chat/completions"][dialect] ?? "responses"
        let streaming = payload["stream"].b || url.contains(":streamGenerateContent")
        if streaming && h["stream_framing"] != "sse" { try unsupported("\(h["stream_framing"].s) framing") }
        let key = streaming && h["paths"].has(endpoint+"/stream") ? endpoint+"/stream" : endpoint
        if h["paths"][key].present && request.present { let model = pathID(request["model"].s).replacingOccurrences(of:"%3A",with:":").replacingOccurrences(of:"%40",with:"@"); url = baseURL + h["paths"][key].s.replacingOccurrences(of:"{model}",with:model) }
        if payload.isObject { if h["model_in"] == "path" { payload = payload.without(["model"]) }; if h["anthropic_version_in"].s.hasPrefix("body:") { payload["anthropic_version"] = j(String(h["anthropic_version_in"].s.dropFirst(5))); headers = headers.without(["anthropic-version"]) } }
        for pair in h["required_headers"].a { headers[pair[0].s.lowercased()] = settings[pair[1].s] }; return (url,payload,headers)
    }
    func resolveCredential() async throws -> Credential {
        let policy = access.value["credential_policy"].s
        if ["oauth","oauth-unless-explicit"].contains(policy) {
            do {
                let local = try Auth.loadOAuth(provider:provider,path:credentialsPath,env:env)
                if policy == "oauth" || local.usable(at:clock()) {
                    let ready = try await Auth.getOAuth(provider:provider,path:credentialsPath,env:env,clock:clock,transport:transport)
                    return .bearerToken(try BearerToken(value:ready.accessToken))
                }
            } catch is NotConfiguredError { if policy == "oauth" { throw NotConfiguredError("\(provider): stored OAuth login is required") } }
        }
        if policy.hasSuffix("-chain") { return try await cloudCache.resolve(now:clock()) { [self] in try await CloudChain(provider:provider,env:env,settings:settings,clock:clock,transport:transport).acquire() } }
        for key in access.value["env_keys"].a.map(\.s) { if let value = env[key], !value.isEmpty { return .apiKey(try ApiKey(value:value)) } }
        if let value = definition["placeholder_key"].isString ? definition["placeholder_key"].s : nil { return .apiKey(try ApiKey(value:value)) }
        throw NotConfiguredError("\(provider): configure credentials")
    }
}
