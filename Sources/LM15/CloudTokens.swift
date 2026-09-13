import Foundation
import Crypto
import _CryptoExtras

public enum CloudTokens {
    public static let jwtBearer = "urn:ietf:params:oauth:grant-type:jwt-bearer"
    public static let assertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    public static let gcpScope = "https://www.googleapis.com/auth/cloud-platform"
    public static func jwt(header: JSONValue, payload: JSONValue, pem: String) throws -> String {
        if pem.contains("ENCRYPTED") { throw NotConfiguredError("encrypted private keys are unsupported") }
        guard let block = pemBlock(pem,labels:["RSA PRIVATE KEY","PRIVATE KEY"]) else { throw NotConfiguredError("RS256 requires a PEM RSA private key") }
        do {
            let key = try _RSA.Signing.PrivateKey(pemRepresentation:block)
            let input = base64URL(try header.jsonData())+"."+base64URL(try payload.jsonData())
            return input+"."+base64URL(try key.signature(for:Data(input.utf8),padding:.insecurePKCS1v1_5).rawRepresentation)
        } catch is LM15Error { throw NotConfiguredError("invalid RSA private key") }
        catch { throw NotConfiguredError("invalid RSA private key") }
    }
    public static func build(provider: String, rung: String, input: JSONValue, settings: JSONValue = [:], now: Date = Date(), env: [String:String] = [:], files: [String:String]? = nil) throws -> JSONValue {
        let url: String; var body: J
        if ["adc-env","adc-file","service-account"].contains(rung) {
            let info = input["credential_file"]; guard info.isObject else { throw ValueError("credential_file must be an object") }
            url = info["token_uri"].or("https://oauth2.googleapis.com/token").s
            var header: J = ["alg":"RS256","typ":"JWT"]; if info["private_key_id"].present { header["kid"] = info["private_key_id"] }
            let payload: J = ["iat":j(Int(now.timeIntervalSince1970)),"exp":j(Int(now.timeIntervalSince1970)+3600),"iss":info["client_email"].or(""),"aud":j(url),"scope":input["scope"].or(j(gcpScope))]
            body = ["grant_type":j(jwtBearer),"assertion":j(try jwt(header:header,payload:payload,pem:info["private_key"].s))]
        } else if rung == "environment" {
            let env = input["env"].isObject ? input["env"].o.mapValues(\.s) : env, settings = input["settings"].or(settings)
            guard let tenant = env["AZURE_TENANT_ID"], let client = env["AZURE_CLIENT_ID"] else { throw NotConfiguredError("Azure environment requires tenant and client IDs") }
            let authority = settings["authority_host"].or(env["AZURE_AUTHORITY_HOST"].map(j) ?? "https://login.microsoftonline.com").s.replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression)
            url = authority+"/"+tenant+"/oauth2/v2.0/token"; body = ["client_id":j(client),"scope":settings["scope"].or("https://ai.azure.com/.default")]
            if let secret = env["AZURE_CLIENT_SECRET"] { body["client_secret"] = j(secret) }
            else if let path = env["AZURE_CLIENT_CERTIFICATE_PATH"] {
                if env["AZURE_CLIENT_CERTIFICATE_PASSWORD"] != nil { throw NotConfiguredError("password-protected certificates are unsupported") }
                let pem: String
                if input["certificate_pem"].present { pem = input["certificate_pem"].s+"\n"+input["private_key_pem"].s }
                else if let files { guard let text = files[path] else { throw NotConfiguredError("certificate is unreadable") }; pem = text }
                else { guard let text = try? String(contentsOfFile:path,encoding:.utf8) else { throw NotConfiguredError("certificate is unreadable") }; pem = text }
                guard let cert = pemBlock(pem,labels:["CERTIFICATE"]), let der = pemDER(cert) else { throw NotConfiguredError("invalid certificate PEM") }
                var header: J = ["alg":"RS256","typ":"JWT","x5t":j(base64URL(Data(Insecure.SHA1.hash(data:der))))]
                if ["true","1"].contains((env["AZURE_CLIENT_SEND_CERTIFICATE_CHAIN"] ?? "").lowercased()) { header["x5c"] = [j(der.base64EncodedString())] }
                let payload: J = ["aud":j(url),"iss":j(client),"sub":j(client),"exp":j(Int(now.timeIntervalSince1970)+600),"iat":j(Int(now.timeIntervalSince1970)),"jti":input["jti"].or(j(UUID().uuidString.lowercased()))]
                body["client_assertion_type"] = j(assertionType); body["client_assertion"] = j(try jwt(header:header,payload:payload,pem:pem))
            } else { throw NotConfiguredError("Azure environment needs a secret or certificate") }
            body["grant_type"] = "client_credentials"
        } else { throw ValueError("no deterministic token request for \(rung)") }
        return ["method":"POST","url":j(url),"headers":["content-type":"application/x-www-form-urlencoded"],"body_encoding":"form","body":body]
    }
    public static func parse(provider: String, rung: String, status: Int, body: JSONValue, now: Date = Date()) throws -> Credential {
        let aws = ["credential_process","imds","container"].contains(rung), ok = rung == "credential_process" ? status == 0 && body["Version"] == 1 : (200..<300).contains(status)
        guard ok else { throw AuthError("\(rung): token request failed",metadata:["provider":j(provider)]) }
        if aws {
            guard body["AccessKeyId"].isString && body["SecretAccessKey"].isString else { throw AuthError("AWS credential response is missing keys") }
            return .aws(try AwsCredentials(accessKeyId:body["AccessKeyId"].s,secretAccessKey:body["SecretAccessKey"].s,sessionToken:body["Token"].or(body["SessionToken"]).isNull ? nil : body["Token"].or(body["SessionToken"]).s,expiresAt:parseDate(body["Expiration"].s)))
        }
        guard body["access_token"].isString && !body["access_token"].empty else { throw AuthError("token response is missing access_token") }
        var expiry: Date?
        if let n = Double(body["expires_on"].stringValue), n.isFinite { expiry = Date(timeIntervalSince1970:n.rounded(.towardZero)) }
        if expiry == nil, let n = Double(body["expires_in"].stringValue), n.isFinite { expiry = now.addingTimeInterval(n.rounded(.towardZero)) }
        return .bearerToken(try BearerToken(value:body["access_token"].s,expiresAt:expiry))
    }
}
func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
func decodeBase64URL(_ text: String) -> Data? { let s = text.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/"); return Data(base64Encoded:s+String(repeating:"=",count:(4-s.utf8.count%4)%4)) }
func pemBlock(_ pem: String, labels: [String]) -> String? { for label in labels { if let start = pem.range(of:"-----BEGIN \(label)-----"), let end = pem.range(of:"-----END \(label)-----",range:start.upperBound..<pem.endIndex) { return String(pem[start.lowerBound..<end.upperBound]) } }; return nil }
func pemDER(_ pem: String) -> Data? { Data(base64Encoded:pem.split(separator:"\n").filter { !$0.hasPrefix("-----") }.joined().filter { !$0.isWhitespace }) }
