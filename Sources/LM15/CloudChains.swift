import Foundation
import Crypto
#if canImport(FoundationXML)
import FoundationXML
#endif

extension CloudChain {
    func http(_ method: String, _ url: String, headers: J = [:], body: Data = Data(), params: J = [:], timeout: TimeInterval = 30) async throws -> HTTPResponse { try await transport.send(TransportRequest(method:method,url:url,headers:headers,body:body,params:params,timeout:timeout)) }
    func exchange(_ method: String, _ url: String, headers: J = [:], body: Data = Data(), params: J = [:], form: J = .null, json: J = .null, timeout: TimeInterval = 30) async throws -> J {
        var h = headers, bytes = body
        if form.present { h["content-type"] = "application/x-www-form-urlencoded"; bytes = formData(form) } else if json.present { h["content-type"] = "application/json"; bytes = try json.jsonData() }
        let res = try await http(method,url,headers:h,body:bytes,params:params,timeout:timeout)
        guard (200..<300).contains(res.status) else { throw AuthError("\(provider): credential exchange failed (HTTP \(res.status))") }
        guard let d = try? res.json(), d.isObject else { throw AuthError("credential exchange returned invalid JSON") }; return d
    }
    func run(_ argv: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let first = argv.first, let path = onPath(first) else { throw NotConfiguredError("credential command was not found on PATH") }
        return try await CredentialProcess.run(executable:Auth.expand(path,env:env),arguments:Array(argv.dropFirst()),environment:env,timeout:timeout)
    }
    func runJSON(_ argv: [String], timeout: TimeInterval = 30) async throws -> J { let text = try await run(argv,timeout:timeout); guard let d = try? J.parse(text), d.isObject else { throw AuthError("credential command returned invalid JSON") }; return d }
    func bearer(_ data: J) throws -> Credential { try CloudTokens.parse(provider:provider,rung:"metadata",status:200,body:data,now:clock()) }
    func awsResponse(_ data: J) throws -> Credential {
        var expiry = data["Expiration"].or(data["expiration"]).or(data["expiresAt"])
        if expiry.isNumber { expiry = j(isoDate(Date(timeIntervalSince1970:expiry.d > 1e11 ? expiry.d/1000 : expiry.d))) }
        return try CloudTokens.parse(provider:provider,rung:"imds",status:200,body:["AccessKeyId":data["AccessKeyId"].or(data["accessKeyId"]),"SecretAccessKey":data["SecretAccessKey"].or(data["secretAccessKey"]),"SessionToken":data["SessionToken"].or(data["Token"]).or(data["sessionToken"]),"Expiration":expiry],now:clock())
    }
    func stsCredentials(_ data: Data) throws -> Credential { let delegate = STSXML(); let parser = XMLParser(data:data); parser.delegate = delegate; parser.shouldResolveExternalEntities = false; guard parser.parse() else { throw AuthError("STS returned invalid XML") }; return try awsResponse(delegate.value) }
    func region() throws -> String {
        if settings["region"].present { return settings["region"].s }
        if let value = env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] { return value }
        return try profileSection()["region"].or("us-east-1").s
    }
    func awsEnv() throws -> Credential? { try staticAWS(["aws_access_key_id":env["AWS_ACCESS_KEY_ID"].map(j) ?? .null,"aws_secret_access_key":env["AWS_SECRET_ACCESS_KEY"].map(j) ?? .null,"aws_session_token":env["AWS_SESSION_TOKEN"].map(j) ?? .null]) }
    func assumeRole(_ sec: J, depth: Int = 0) async throws -> Credential {
        if depth > 5 { throw AuthError("assume-role source chain is too deep") }; let source: Credential?
        if sec["source_profile"].present {
            let c = try awsConfig(), name = sec["source_profile"].s
            let sub = c.config[name == "default" ? name : "profile "+name].or(c.config[name]).or([:]).merging(c.credentials[name])
            source = sub["role_arn"].present ? try await assumeRole(sub,depth:depth+1) : try staticAWS(sub)
        } else { switch sec["credential_source"].s { case "Environment":source = try awsEnv(); case "EcsContainer":source = try await acquireRung("container"); case "Ec2InstanceMetadata":source = try await acquireRung("imds"); default:source = nil } }
        guard case .aws(let aws) = source else { throw NotConfiguredError("assume-role source credentials are missing") }
        var payload: J = ["Action":"AssumeRole","Version":"2011-06-15","RoleArn":sec["role_arn"],"RoleSessionName":sec["role_session_name"].or(j("lm15-"+UUID().uuidString))]
        for (k,v) in ["ExternalId":"external_id","DurationSeconds":"duration_seconds"] where sec[v].present { payload[k] = sec[v] }
        let region = try region(), url = "https://sts.\(region).amazonaws.com/", body = formData(payload)
        let signed = try SigV4.sign(method:"POST",url:url,headers:["content-type":"application/x-www-form-urlencoded"],body:body,credential:aws,region:region,service:"sts",now:clock())
        let res = try await http("POST",url,headers:signed["headers"],body:body); guard (200..<300).contains(res.status) else { throw AuthError("STS AssumeRole failed") }; return try stsCredentials(res.body)
    }
    func awsSSO() async throws -> Credential {
        let c = try awsConfig(), sec = try profileSection(), session = sec["sso_session"]
        let merged = session.present ? c.config["sso-session "+session.s].or([:]).merging(sec) : sec
        let key = Data(Insecure.SHA1.hash(data:Data(session.or(sec["sso_start_url"]).s.utf8))).hex, path = "~/.aws/sso/cache/\(key).json"
        guard let token = json(path) else { throw NotConfiguredError("no cached SSO token; run aws sso login") }; let region = merged["sso_region"].or("us-east-1").s
        var access = token["accessToken"]; let expiry = parseDate(token["expiresAt"].s)
        if access.isNull || expiry.map({ $0 <= clock().addingTimeInterval(Auth.refreshSkew) }) == true {
            guard ["refreshToken","clientId","clientSecret"].allSatisfy({ token[$0].present }) else { throw NotConfiguredError("SSO token expired; run aws sso login") }
            access = try await Auth.withFileLock(Auth.expand(path,env:env),env:env) {
                var fresh = json(path) ?? token
                if fresh["accessToken"].present, let expiry = parseDate(fresh["expiresAt"].s), expiry > clock().addingTimeInterval(Auth.refreshSkew) { return fresh["accessToken"] }
                let d = try await exchange("POST","https://oidc.\(region).amazonaws.com/token",json:["clientId":fresh["clientId"],"clientSecret":fresh["clientSecret"],"grantType":"refresh_token","refreshToken":fresh["refreshToken"]])
                guard d["accessToken"].present else { throw AuthError("SSO refresh returned no token") }
                fresh["accessToken"] = d["accessToken"]; if d["refreshToken"].present { fresh["refreshToken"] = d["refreshToken"] }; fresh["expiresAt"] = j(isoDate(clock().addingTimeInterval(d["expiresIn"].or(3600).d)))
                try Auth.writePrivateJSONAtomic(Auth.expand(path,env:env),value:fresh); return d["accessToken"]
            }
        }
        guard merged["sso_account_id"].present && merged["sso_role_name"].present else { throw NotConfiguredError("SSO profile needs account and role") }
        return try await awsResponse(exchange("GET","https://portal.sso.\(region).amazonaws.com/federation/credentials",headers:["x-amz-sso_bearer_token":access],params:["role_name":merged["sso_role_name"],"account_id":merged["sso_account_id"]])["roleCredentials"].or([:]))
    }
    var azureScope: String { settings["scope"].or("https://ai.azure.com/.default").s }
    var azureTokenURL: String { settings["authority_host"].or(env["AZURE_AUTHORITY_HOST"].map(j) ?? "https://login.microsoftonline.com").s.replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression)+"/"+(env["AZURE_TENANT_ID"] ?? "")+"/oauth2/v2.0/token" }
    func managedIdentity() async throws -> Credential? {
        let resource = azureScope.hasSuffix("/.default") ? String(azureScope.dropLast(9)) : azureScope; var params: J = ["resource":j(resource)]
        if let client = env["AZURE_CLIENT_ID"] { params["client_id"] = j(client) }
        if let url = env["IDENTITY_ENDPOINT"], let header = env["IDENTITY_HEADER"] {
            if env["IDENTITY_SERVER_THUMBPRINT"] != nil { throw NotConfiguredError("Service Fabric TLS pinning is unsupported; pass a credential") }
            return try await bearer(exchange("GET",url,headers:["x-identity-header":j(header)],params:params.with("api-version","2019-08-01")))
        }
        if let url = env["MSI_ENDPOINT"] {
            if let secret = env["MSI_SECRET"] { if params["client_id"].present { params["clientid"] = params["client_id"]; params = params.without(["client_id"]) }; return try await bearer(exchange("GET",url,headers:["secret":j(secret)],params:params.with("api-version","2017-09-01"))) }
            return try await bearer(exchange("POST",url,headers:["metadata":"true"],form:["resource":j(resource)]))
        }
        if let url = env["IDENTITY_ENDPOINT"], env["IMDS_ENDPOINT"] != nil {
            let query: J = ["api-version":"2019-11-01","resource":j(resource)], res = try await http("GET",url,headers:["metadata":"true"],params:query,timeout:5)
            let challenge = res.headers["www-authenticate"].s
            guard res.status == 401, let range = challenge.range(of:"realm=") else { throw AuthError("Azure Arc expected a 401 challenge") }
            let path = String(challenge[range.upperBound...]).trimmingCharacters(in:CharacterSet.whitespaces.union(CharacterSet(charactersIn:"\"")))
            guard URL(fileURLWithPath:path).deletingLastPathComponent().path == "/var/opt/azcmagent/tokens", path.hasSuffix(".key"), let secret = read(path), secret.utf8.count <= 4096 else { throw AuthError("invalid Azure Arc challenge key") }
            return try await bearer(exchange("GET",url,headers:["metadata":"true","authorization":j("Basic "+secret.trimmingCharacters(in:.whitespacesAndNewlines))],params:query))
        }
        do { let res = try await http("GET","http://169.254.169.254/metadata/identity/oauth2/token",headers:["metadata":"true"],params:params.with("api-version","2018-02-01"),timeout:1); return res.status == 200 ? try bearer(res.json()) : nil }
        catch is TransportError { return nil } catch is TimeoutError { return nil }
    }
    func gcpFromInfo(_ info: J, depth: Int = 0) async throws -> Credential {
        if depth > 5 { throw NotConfiguredError("Google credential nesting is too deep") }
        switch info["type"].s {
        case "authorized_user":
            guard ["refresh_token","client_id","client_secret"].allSatisfy({ info[$0].present }) else { throw NotConfiguredError("authorized_user credentials are incomplete") }
            return try await bearer(exchange("POST",info["token_uri"].or("https://oauth2.googleapis.com/token").s,form:["grant_type":"refresh_token","client_id":info["client_id"],"client_secret":info["client_secret"],"refresh_token":info["refresh_token"]]))
        case "service_account": let req = try CloudTokens.build(provider:provider,rung:"service-account",input:["credential_file":info],now:clock()); return try await bearer(exchange("POST",req["url"].s,form:req["body"]))
        case "impersonated_service_account":
            guard info["source_credentials"].isObject else { throw NotConfiguredError("impersonation requires source_credentials") }
            return try await gcpImpersonate(gcpFromInfo(info["source_credentials"],depth:depth+1),url:info["service_account_impersonation_url"].s,delegates:info["delegates"].or([]))
        case "external_account":
            let source = info["credential_source"]; var format = source["format"], subject: String?
            if source.has("environment_id") { throw NotConfiguredError("Google external_account AWS sources are unsupported; use a file, URL or executable") }
            if source["file"].present { subject = read(source["file"].s)?.trimmingCharacters(in:.whitespacesAndNewlines) }
            else if source["url"].present { let res = try await http("GET",source["url"].s,headers:source["headers"].or([:])); guard (200..<300).contains(res.status) else { throw AuthError("subject token URL request failed") }; subject = String(decoding:res.body,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines) }
            else if source["executable"].isObject {
                guard env["GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES"] == "1" else { throw NotConfiguredError("executable source requires GOOGLE_EXTERNAL_ACCOUNT_ALLOW_EXECUTABLES=1") }
                let exe = source["executable"], d = try await runJSON(shellWords(exe["command"].s),timeout:exe["timeout_millis"].or(30_000).d/1000)
                if d["success"] == false { throw AuthError("external account executable reported failure") }; format = ["type":"text"]; subject = d["id_token"].or(d["saml_response"]).isNull ? nil : d["id_token"].or(d["saml_response"]).s
            }
            guard var subject else { throw NotConfiguredError("external account needs a readable subject token source") }
            if format["type"] == "json" { guard let d = try? J.parse(subject), d[format["subject_token_field_name"].s].isString else { throw AuthError("subject token source returned invalid JSON") }; subject = d[format["subject_token_field_name"].s].s }
            let payload: J = ["grantType":"urn:ietf:params:oauth:grant-type:token-exchange","audience":info["audience"],"scope":j(CloudTokens.gcpScope),"requestedTokenType":"urn:ietf:params:oauth:token-type:access_token","subjectToken":j(subject),"subjectTokenType":info["subject_token_type"]]
            let token = try await bearer(exchange("POST",info["token_url"].or("https://sts.googleapis.com/v1/token").s,json:payload))
            return info["service_account_impersonation_url"].present ? try await gcpImpersonate(token,url:info["service_account_impersonation_url"].s,delegates:[]) : token
        default: throw NotConfiguredError("unsupported Google credential type; provide an explicit credential")
        }
    }
    func gcpImpersonate(_ source: Credential, url: String, delegates: J) async throws -> Credential {
        guard case .bearerToken(let token) = source else { throw NotConfiguredError("impersonation needs a bearer token") }
        let d = try await exchange("POST",url,headers:["authorization":j("Bearer "+token.value)],json:["delegates":delegates,"scope":[j(CloudTokens.gcpScope)],"lifetime":"3600s"])
        guard d["accessToken"].isString else { throw AuthError("Google impersonation returned no token") }; return .bearerToken(try BearerToken(value:d["accessToken"].s,expiresAt:parseDate(d["expireTime"].s)))
    }
    func acquireRung(_ name: String) async throws -> Credential? {
        if name.hasPrefix("env:") { if name == "env:AWS_ACCESS_KEY_ID" { return try awsEnv() }; let key = String(name.dropFirst(4)); guard let value = env[key], !value.isEmpty else { return nil }; return key == "AWS_BEARER_TOKEN_BEDROCK" ? .bearerToken(try BearerToken(value:value)) : .apiKey(try ApiKey(value:value)) }
        switch name {
        case "shared-credentials-file": let c = try awsConfig(); return try staticAWS(c.credentials[c.profile])
        case "config-file": return try staticAWS(profileSection())
        case "assume-role": return try await assumeRole(profileSection())
        case "web-identity":
            let sec = try profileSection(), file = env["AWS_WEB_IDENTITY_TOKEN_FILE"] ?? (sec["web_identity_token_file"].isNull ? nil : sec["web_identity_token_file"].s)
            guard let token = read(file) else { throw NotConfiguredError("web identity token file is unreadable") }
            let payload: J = ["Action":"AssumeRoleWithWebIdentity","Version":"2011-06-15","RoleArn":env["AWS_ROLE_ARN"].map(j) ?? sec["role_arn"],"RoleSessionName":env["AWS_ROLE_SESSION_NAME"].map(j) ?? sec["role_session_name"].or(j("lm15-"+UUID().uuidString)),"WebIdentityToken":j(token.trimmingCharacters(in:.whitespacesAndNewlines))]
            let res = try await http("POST","https://sts.\(region()).amazonaws.com/",headers:["content-type":"application/x-www-form-urlencoded"],body:formData(payload)); guard (200..<300).contains(res.status) else { throw AuthError("STS web identity request failed") }; return try stsCredentials(res.body)
        case "sso": return try await awsSSO()
        case "login":
            let sec = try profileSection(), path = (env["AWS_LOGIN_CACHE_DIRECTORY"] ?? "~/.aws/login/cache")+"/"+sha256(Data(sec["login_session"].s.utf8))+".json"
            guard let d = json(path), d["accessToken"].isObject else { throw NotConfiguredError("AWS login session missing; run aws login") }
            let c = try awsResponse(d["accessToken"]); if let expiry = credentialExpiry(c), expiry <= clock().addingTimeInterval(Auth.refreshSkew) { throw NotConfiguredError("AWS login session expired; run aws login") }; return c
        case "credential_process": let d = try await runJSON(shellWords(profileSection()["credential_process"].s),timeout:60); guard d["Version"] == 1 else { throw AuthError("credential_process Version must be 1") }; return try awsResponse(d)
        case "container": guard let url = try containerURL() else { return nil }; let token = env["AWS_CONTAINER_AUTHORIZATION_TOKEN"] ?? read(env["AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"])?.trimmingCharacters(in:.whitespacesAndNewlines); return try await awsResponse(exchange("GET",url,headers:token.map { ["authorization":j($0)] } ?? [:],timeout:5))
        case "imds":
            if (env["AWS_EC2_METADATA_DISABLED"] ?? "").lowercased() == "true" { return nil }
            let base = (env["AWS_EC2_METADATA_SERVICE_ENDPOINT"] ?? ((env["AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE"] ?? "").lowercased() == "ipv6" ? "http://[fd00:ec2::254]" : "http://169.254.169.254")).replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression)
            let res: HTTPResponse
            do { res = try await http("PUT",base+"/latest/api/token",headers:["x-aws-ec2-metadata-token-ttl-seconds":"21600"],timeout:1) } catch is TransportError { return nil } catch is TimeoutError { return nil }
            if res.status != 200 { return nil }; let headers: J = ["x-aws-ec2-metadata-token":j(String(decoding:res.body,as:UTF8.self))]
            let role = try await http("GET",base+"/latest/meta-data/iam/security-credentials/",headers:headers,timeout:1), text = String(decoding:role.body,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            if role.status != 200 || text.isEmpty { return nil }
            let response = try await http("GET",base+"/latest/meta-data/iam/security-credentials/"+pathID(text.components(separatedBy:"\n")[0]),headers:headers,timeout:1); if response.status != 200 { return nil }
            let d = try response.json(); if d["Code"].present && d["Code"] != "Success" { throw AuthError("IMDS rejected credential request") }; return try awsResponse(d)
        case "environment": let request = try CloudTokens.build(provider:provider,rung:"environment",input:["env":.object(env.mapValues(j)),"settings":settings],settings:settings,now:clock(),env:env,files:files); return try await bearer(exchange("POST",request["url"].s,form:request["body"]))
        case "workload-identity":
            guard let token = read(env["AZURE_FEDERATED_TOKEN_FILE"]) else { throw NotConfiguredError("Azure federated token file is unreadable") }
            return try await bearer(exchange("POST",azureTokenURL,form:["client_id":env["AZURE_CLIENT_ID"].map(j) ?? .null,"scope":j(azureScope),"client_assertion_type":j(CloudTokens.assertionType),"client_assertion":j(token.trimmingCharacters(in:.whitespacesAndNewlines)),"grant_type":"client_credentials"]))
        case "managed-identity": return try await managedIdentity()
        case "az":
            var argv = ["az","account","get-access-token","--output","json","--scope",azureScope]; if let tenant = env["AZURE_TENANT_ID"] { argv += ["--tenant",tenant] }
            let d = try await runJSON(argv); if d["accessToken"].isNull { return nil }; var c = try bearer(["access_token":d["accessToken"],"expires_on":d["expires_on"]]); if credentialExpiry(c) == nil, let date = parseDate(d["expiresOn"].s) { c = .bearerToken(try BearerToken(value:d["accessToken"].s,expiresAt:date)) }; return c
        case "pwsh":
            let resource = (azureScope.hasSuffix("/.default") ? String(azureScope.dropLast(9)) : azureScope).replacingOccurrences(of:"'",with:"''")
            let d = try await runJSON(["pwsh","-NoProfile","-NonInteractive","-Command","Get-AzAccessToken -ResourceUrl '\(resource)' -AsSecureString:$false | ConvertTo-Json -Compress"]); return d["Token"].isNull ? nil : try bearer(["access_token":d["Token"]])
        case "azd": let d = try await runJSON(["azd","auth","token","--output","json","--scope",azureScope]); return d["token"].isNull ? nil : .bearerToken(try BearerToken(value:d["token"].s,expiresAt:parseDate(d["expiresOn"].s)))
        case "adc-env","adc-file": guard let d = json(name == "adc-env" ? env["GOOGLE_APPLICATION_CREDENTIALS"] : adcPath) else { return nil }; return try await gcpFromInfo(d)
        case "metadata":
            if ["1","true"].contains((env["NO_GCE_CHECK"] ?? "").lowercased()) { return nil }; let host = env["GCE_METADATA_HOST"] ?? env["GCE_METADATA_ROOT"] ?? "metadata.google.internal"
            do { let res = try await http("GET","http://\(host)/computeMetadata/v1/instance/service-accounts/default/token",headers:["metadata-flavor":"Google"],timeout:1); return res.status == 200 ? try bearer(res.json()) : nil } catch is TransportError { return nil } catch is TimeoutError { return nil }
        case "gcloud": let token = try await run(["gcloud","auth","print-access-token"]).trimmingCharacters(in:.whitespacesAndNewlines); return token.isEmpty ? nil : .bearerToken(try BearerToken(value:token))
        default: throw NotConfiguredError("unknown credential rung \(name)")
        }
    }
    public func acquire() async throws -> Credential {
        let resolved = try resolveSettings()
        if resolved != settings { return try await CloudChain(provider:provider,env:env,files:files,settings:resolved,clock:clock,transport:transport).acquire() }
        for (name,verdict) in try rungs() where verdict != "absent" {
            do { if let c = try await acquireRung(name) { return c } }
            catch is AuthError { if policy["credential_policy"] == "azure-chain" && ["az","pwsh","azd"].contains(name) { continue }; throw AuthError("\(provider): credential acquisition failed at \(name)") }
        }; throw NotConfiguredError("\(provider): no cloud credentials resolved; configure a credential source or pass an explicit credential")
    }
}
func credentialExpiry(_ c: Credential) -> Date? { switch c { case .apiKey:return nil; case .bearerToken(let x):return x.expiresAt; case .aws(let x):return x.expiresAt } }
private final class STSXML: NSObject, XMLParserDelegate {
    var value: J = [:], inCredentials = false, name = "", text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String:String]) { let local = elementName.components(separatedBy:":").last!; if local == "Credentials" { inCredentials = true }; name = local; text = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { let local = elementName.components(separatedBy:":").last!; if local == "Credentials" { inCredentials = false } else if inCredentials { value[local] = j(text.trimmingCharacters(in:.whitespacesAndNewlines)) } }
}
actor CredentialCache {
    private var value: Credential?, inFlight: Task<Credential, any Error>?
    func resolve(now: Date, operation: @escaping @Sendable () async throws -> Credential) async throws -> Credential {
        if let value, let expiry = credentialExpiry(value), expiry > now.addingTimeInterval(Auth.refreshSkew) { return value }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }; inFlight = task
        do { let c = try await task.value; value = c; inFlight = nil; return c } catch { inFlight = nil; throw error }
    }
}
