import Foundation

public struct AuthStep: Sendable, Equatable {
    public let kind: String, source: String, detail: String, state: String
    public func toJSON() -> JSONValue { ["kind":j(kind),"source":j(source),"detail":j(detail),"state":j(state)] }
}
public struct AuthReport: Sendable, CustomStringConvertible {
    public let provider: String, steps: [AuthStep], configured: Bool, settings: JSONValue
    public var description: String { (["auth for \(provider):"]+steps.map { "  \($0.state): \($0.source) — \($0.detail)" }+["configured: \(configured ? "yes" : "no")"]+settings.o.keys.sorted().map { "setting \($0): \(settings[$0].s)" }).joined(separator:"\n") }
}
public struct CloudChain: Sendable, CustomStringConvertible {
    public let provider: String, env: [String:String], files: [String:String]?, settings: JSONValue, transport: any HTTPTransport
    let policy: J, clock: Clock
    public init(provider: String, env: [String:String] = Environment.current, files: [String:String]? = nil, settings: JSONValue = [:], clock: @escaping Clock = { Date() }, transport: any HTTPTransport = URLSessionTransport()) { self.provider = provider; self.env = env; self.files = files; self.settings = settings; self.clock = clock; self.transport = transport; policy = Tables.data["providers"][provider]["access"] }
    public var description: String { "CloudChain(provider: \(provider))" }
    func read(_ path: String?) -> String? { Auth.read(path,env:env,files:files) }
    func json(_ path: String?) -> J? { guard let path else { return nil }; return Auth.readJSON(path,env:env,files:files) }
    func onPath(_ command: String) -> String? {
        if command.isEmpty { return nil }
        let paths = command.contains("/") ? [command] : (env["PATH"] ?? "").components(separatedBy:":").map { $0+"/"+command }
        return paths.first { if files != nil { return read($0) != nil }; let path = Auth.expand($0,env:env); var directory: ObjCBool = false; return FileManager.default.isExecutableFile(atPath:path) && FileManager.default.fileExists(atPath:path,isDirectory:&directory) && !directory.boolValue }
    }
    func ini(_ path: String) throws -> J {
        var out: J = [:], current: String?
        for raw in (read(path) ?? "").components(separatedBy:"\n") {
            let line = raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { current = String(line.dropFirst().dropLast()).trimmingCharacters(in:.whitespaces); if out[current!].isNull { out[current!] = [:] } }
            else if let current, let split = line.firstIndex(where: { $0 == "=" || $0 == ":" }) { let key = String(line[..<split]).trimmingCharacters(in:.whitespaces).lowercased(), value = String(line[line.index(after:split)...]).trimmingCharacters(in:.whitespaces); out[current][key] = j(value) }
            else if !raw.hasPrefix(" ") && !raw.hasPrefix("\t") { throw NotConfiguredError("malformed AWS profile configuration") }
        }; return out
    }
    func awsConfig() throws -> (credentials: J, config: J, profile: String) { (try ini(env["AWS_SHARED_CREDENTIALS_FILE"] ?? "~/.aws/credentials"),try ini(env["AWS_CONFIG_FILE"] ?? "~/.aws/config"),env["AWS_PROFILE"] ?? env["AWS_DEFAULT_PROFILE"] ?? "default") }
    func profileSection() throws -> J { let c = try awsConfig(); return c.config[c.profile == "default" ? c.profile : "profile "+c.profile].or(c.config[c.profile]).or([:]) }
    func staticAWS(_ section: J) throws -> Credential? { guard section["aws_access_key_id"].present && section["aws_secret_access_key"].present else { return nil }; return .aws(try AwsCredentials(accessKeyId:section["aws_access_key_id"].s,secretAccessKey:section["aws_secret_access_key"].s,sessionToken:section["aws_session_token"].isNull ? nil : section["aws_session_token"].s)) }
    var adcPath: String { (env["CLOUDSDK_CONFIG"] ?? "~/.config/gcloud")+"/application_default_credentials.json" }
    public func resolveSettings() throws -> JSONValue {
        let host = policy["host"]; if host.isNull { return settings }; var s = settings
        let known = Set(host["settings"].a.map { $0["name"].s }); if !Set(s.o.keys).isSubset(of:known) { throw ValueError("unknown host setting") }
        for setting in host["settings"].a {
            let name = setting["name"].s
            if s[name].isNull { for key in setting["env"].a.map(\.s) { if let v = env[key], !v.isEmpty { s[name] = j(v); break } } }
            if s[name].isNull && policy["credential_policy"] == "aws-chain" && name == "region" { s[name] = try profileSection()["region"] }
            if s[name].isNull && policy["credential_policy"] == "gcp-chain" && name == "project" { let d = json(env["GOOGLE_APPLICATION_CREDENTIALS"]) ?? json(adcPath) ?? [:]; s[name] = d["quota_project_id"].or(d["project_id"]) }
            s[name] = s[name].or(setting["default"]); if s[name].isNull { throw NotConfiguredError("\(provider): required host setting \(name) is missing") }
        }; return s
    }
    func narrowed(_ name: String, developer: Bool = false) -> Bool {
        let selected = (env["AZURE_TOKEN_CREDENTIALS"] ?? "").lowercased(); if selected.isEmpty { return false }; if selected == "prod" { return developer }; if selected == "dev" { return !developer }; return selected != name.lowercased()
    }
    func containerURL() throws -> String? {
        if let relative = env["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] {
            guard relative.hasPrefix("/") && !relative.hasPrefix("//") && !relative.contains(where: { "\\\r\n\t#".contains($0) }) else { throw NotConfiguredError("invalid container credential relative URI") }; return "http://169.254.170.2"+relative
        }
        guard let full = env["AWS_CONTAINER_CREDENTIALS_FULL_URI"] else { return nil }
        guard let u = URLComponents(string:full), u.user == nil, u.password == nil, u.fragment == nil else { throw NotConfiguredError("invalid container credential URL") }
        let host = (u.host ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        guard u.scheme == "https" || u.scheme == "http" && ["localhost","127.0.0.1","::1","169.254.170.2","169.254.170.23","fd00:ec2::23"].contains(host) else { throw NotConfiguredError("untrusted container credential URL") }; return full
    }
    func rungs() throws -> [(String,String)] {
        var out = policy["env_keys"].a.map { ($0.s,(env[$0.s] ?? "").isEmpty ? "absent" : "usable") }.map { ("env:"+$0.0,$0.1) }
        func verdict(_ present: Bool, usable: Bool = false) -> String { present ? (usable ? "usable" : "configured") : "absent" }
        switch policy["credential_policy"].s {
        case "aws-chain":
            let c = try awsConfig(), sec = try profileSection()
            out += [
                ("env:AWS_ACCESS_KEY_ID",verdict(env["AWS_ACCESS_KEY_ID"] != nil && env["AWS_SECRET_ACCESS_KEY"] != nil,usable:true)),
                ("assume-role",verdict(sec["role_arn"].present && (sec["source_profile"].present || sec["credential_source"].present))),
                ("web-identity",verdict((env["AWS_WEB_IDENTITY_TOKEN_FILE"] != nil || sec["web_identity_token_file"].present) && (env["AWS_ROLE_ARN"] != nil || sec["role_arn"].present))),
                ("sso",verdict(sec["sso_session"].present || sec["sso_start_url"].present)),
                ("shared-credentials-file",verdict(try staticAWS(c.credentials[c.profile]) != nil,usable:true)),
                ("login",verdict(sec["login_session"].present)),
                ("credential_process",verdict(sec["credential_process"].present && onPath((try? shellWords(sec["credential_process"].s).first) ?? "") != nil)),
                ("config-file",verdict(try staticAWS(sec) != nil,usable:true)),
                ("container",verdict(try containerURL() != nil)),
                ("imds",verdict((env["AWS_EC2_METADATA_DISABLED"] ?? "").lowercased() != "true"))
            ]
        case "azure-chain":
            let identity = env["AZURE_TENANT_ID"] != nil && env["AZURE_CLIENT_ID"] != nil
            out += [("environment",verdict(!narrowed("EnvironmentCredential") && identity && (env["AZURE_CLIENT_SECRET"] != nil || env["AZURE_CLIENT_CERTIFICATE_PATH"] != nil))),("workload-identity",verdict(!narrowed("WorkloadIdentityCredential") && identity && env["AZURE_FEDERATED_TOKEN_FILE"] != nil)),("managed-identity",verdict(!narrowed("ManagedIdentityCredential")))]
            for (command,type) in [("az","AzureCliCredential"),("pwsh","AzurePowerShellCredential"),("azd","AzureDeveloperCliCredential")] { out.append((command,verdict(!narrowed(type,developer:true) && onPath(command) != nil))) }
        case "gcp-chain": out += [("adc-env",verdict(json(env["GOOGLE_APPLICATION_CREDENTIALS"]) != nil)),("adc-file",verdict(json(adcPath) != nil)),("metadata",verdict(!["1","true"].contains((env["NO_GCE_CHECK"] ?? "").lowercased()))),("gcloud",verdict(onPath("gcloud") != nil))]
        default: break
        }; return out
    }
    func explain(explicit: Bool) throws -> AuthReport {
        var selected = explicit, steps = [AuthStep(kind:"api_keys",source:"explicit api_keys entry",detail:explicit ? "provided (value never shown)" : "not provided",state:explicit ? "selected" : "absent")]
        for (name,verdict) in try rungs() { let state = verdict == "absent" ? "absent" : selected ? "shadowed" : verdict == "configured" ? "unprobed" : "selected"; if state == "selected" { selected = true }; steps.append(AuthStep(kind:name,source:name,detail:verdict == "configured" ? "checked at request time" : verdict == "usable" ? "provided (value never shown)" : "not configured",state:state)) }
        let shown: J; do { shown = try resolveSettings() } catch let e as NotConfiguredError { shown = ["error":j(e.message)] }
        return AuthReport(provider:provider,steps:steps,configured:selected || steps.contains { $0.state == "unprobed" },settings:shown)
    }
}
public func explainAuth(_ inputProvider: String, env: [String:String] = Environment.current, apiKeys: [String:CredentialSource] = [:], credentialsPath: String? = nil, files: [String:String]? = nil, settings: JSONValue = [:], clock: Clock = { Date() }) throws -> AuthReport {
    let provider = inputProvider.replacingOccurrences(of:"_",with:"-"), definition = Tables.data["providers"][provider]
    guard definition.present else { throw ValueError("unknown provider") }; let policy = definition["access"], mode = policy["credential_policy"].s
    let source = mode == "oauth" ? nil : try apiKeysSource(Array(apiKeys.keys),provider)
    if policy["host"].present || mode.hasSuffix("-chain") { return try CloudChain(provider:provider,env:env,files:files,settings:settings).explain(explicit:source != nil) }
    var steps: [AuthStep] = [], selected = false
    if mode != "oauth" { selected = source != nil; steps.append(AuthStep(kind:"api_keys",source:source.map { "explicit api_keys entry via "+$0 } ?? "explicit api_keys entry",detail:selected ? "provided (value never shown)" : "not provided",state:selected ? "selected" : "absent")) }
    if ["oauth","oauth-unless-explicit"].contains(mode) {
        let usable = (try? Auth.loadOAuth(provider:provider,path:credentialsPath,env:env,files:files).usable(at:clock())) ?? false
        steps.append(AuthStep(kind:"oauth-file",source:"stored OAuth login",detail:usable ? "usable (value never shown)" : "not usable; "+policy["login_hint"].s,state:usable ? (selected ? "shadowed" : "selected") : "absent")); selected = selected || usable
    }
    if mode != "oauth" {
        for key in policy["env_keys"].a.map(\.s) { let present = !(env[key] ?? "").isEmpty; steps.append(AuthStep(kind:"env:"+key,source:"env $"+key,detail:present ? "set (value never shown)" : "not set",state:present ? (selected ? "shadowed" : "selected") : "absent")); selected = selected || present }
        if definition["placeholder_key"].present { steps.append(AuthStep(kind:"placeholder",source:"local-server placeholder key",detail:"preset default",state:selected ? "shadowed" : "selected")); selected = true }
    }
    return AuthReport(provider:provider,steps:steps,configured:selected,settings:[:])
}
/// Shell-like tokenization for credential_process. It never invokes a shell or expands variables.
func shellWords(_ text: String) throws -> [String] {
    var result: [String] = [], word = "", quote: Character?, escape = false, active = false
    for c in text {
        if escape { word.append(c); escape = false; active = true; continue }
        if c == "\\" && quote != "'" { escape = true; active = true; continue }
        if let q = quote { if c == q { quote = nil } else { word.append(c) }; active = true; continue }
        if c == "'" || c == "\"" { quote = c; active = true; continue }
        if c.isWhitespace { if active { result.append(word); word = ""; active = false } } else { word.append(c); active = true }
    }
    if quote != nil || escape { throw NotConfiguredError("malformed credential command") }; if active { result.append(word) }; return result
}
