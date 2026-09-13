import Foundation
import Crypto

extension Auth {
    public struct PKCEPair: Sendable, CustomStringConvertible {
        public let verifier: String, challenge: String
        public var method: String { "S256" }
        public var description: String { "PKCEPair([REDACTED])" }
    }
    public static func pkceChallenge(_ verifier: String) throws -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-".utf8)
        guard (43...128).contains(verifier.utf8.count), verifier.utf8.allSatisfy(allowed.contains) else { throw ValueError("PKCE verifier must be 43–128 unreserved ASCII characters") }
        return base64URL(Data(SHA256.hash(data:Data(verifier.utf8))))
    }
    public static func generatePKCE() throws -> PKCEPair {
        var rng = SystemRandomNumberGenerator(); let verifier = base64URL(Data((0..<64).map { _ in UInt8.random(in:0...255,using:&rng) }))
        return try PKCEPair(verifier:verifier,challenge:pkceChallenge(verifier))
    }
    public struct DeviceAuthorization: Sendable, CustomStringConvertible {
        public let userCode: String, verificationURI: String, verificationURIComplete: String?, intervalSeconds: TimeInterval, expiresInSeconds: TimeInterval, deviceCode: String
        public var description: String { "DeviceAuthorization([REDACTED])" }
        public init(json: JSONValue) throws {
            guard json["device_code"].isString, !json["device_code"].empty, json["user_code"].isString, !json["user_code"].empty, json["expires_in"].isNumber, json["expires_in"].d.isFinite, json["expires_in"].d > 0 else { throw AuthError("device authorization lacks required codes or expiry") }
            func checkedURL(_ s: J) throws -> String { guard s.isString, let url = URLComponents(string:s.s), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { throw AuthError("untrusted device verification URL") }; return s.s }
            deviceCode = json["device_code"].s; userCode = json["user_code"].s; expiresInSeconds = json["expires_in"].d
            intervalSeconds = json["interval"].isNumber && json["interval"].d.isFinite && json["interval"].d > 0 ? json["interval"].d : 5
            verificationURI = try checkedURL(json["verification_uri"]); verificationURIComplete = json["verification_uri_complete"].isNull ? nil : try checkedURL(json["verification_uri_complete"])
        }
    }
    private static func devicePost(_ url: String, payload: J, transport: any HTTPTransport) async throws -> (Int,J) {
        do { let response = try await transport.send(TransportRequest(method:"POST",url:url,headers:["content-type":"application/x-www-form-urlencoded"],body:formData(payload))), data = try response.json(); guard data.isObject else { throw AuthError("invalid device authorization response") }; return (response.status,data) }
        catch is CancellationError { throw CancellationError() } catch { throw AuthError("device authorization request failed") }
    }
    public static func startXAIDeviceLogin(transport: any HTTPTransport = URLSessionTransport()) async throws -> DeviceAuthorization {
        let (status,data) = try await devicePost("https://auth.x.ai/oauth2/device/code",payload:["client_id":j(tokenEndpoints["xai"]!.1),"scope":"openid profile email offline_access grok-cli:access api:access","referrer":"lm15"],transport:transport)
        guard (200..<300).contains(status) else { throw AuthError("xAI device authorization failed") }; return try DeviceAuthorization(json:data)
    }
    public static func pollXAIDeviceLogin(_ device: DeviceAuthorization, transport: any HTTPTransport = URLSessionTransport(), clock: @escaping Clock = { Date() }, sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for:.seconds($0)) }) async throws -> LocalOAuthCredential {
        let deadline = ContinuousClock.now.advanced(by:.seconds(device.expiresInSeconds)); var interval = device.intervalSeconds, elapsed: TimeInterval = 0
        while true {
            try Task.checkCancellation(); guard ContinuousClock.now.advanced(by:.seconds(interval)) < deadline, elapsed+interval < device.expiresInSeconds else { throw AuthError("xAI device code expired") }
            try await sleep(interval); elapsed += interval
            let (status,d) = try await devicePost(tokenEndpoints["xai"]!.0,payload:["grant_type":"urn:ietf:params:oauth:grant-type:device_code","client_id":j(tokenEndpoints["xai"]!.1),"device_code":j(device.deviceCode)],transport:transport)
            if (200..<300).contains(status) {
                guard d["access_token"].isString, !d["access_token"].empty, d["expires_in"].isNumber, d["expires_in"].d.isFinite, d["expires_in"].d > 0 else { throw AuthError("device token response lacks access token or expiry") }
                return LocalOAuthCredential(accessToken:d["access_token"].s,refreshToken:d["refresh_token"].isString ? d["refresh_token"].s : nil,expiresAt:clock().addingTimeInterval(d["expires_in"].d-refreshSkew),accountID:nil,path:"")
            }
            switch d["error"].s {
            case "authorization_pending": continue
            case "slow_down": interval = d["interval"].isNumber && d["interval"].d.isFinite && d["interval"].d > interval ? d["interval"].d : interval+5
            case "access_denied","authorization_denied": throw AuthError("xAI device authorization was denied")
            case "expired_token": throw AuthError("xAI device code expired")
            default: throw AuthError("xAI device token polling failed")
            }
        }
    }
    /// Presents the verification URI/code through a caller-supplied UI; never starts a browser or prints tokens.
    public static func login(provider: String, path: String? = nil, env: [String:String] = Environment.current, transport: any HTTPTransport = URLSessionTransport(), clock: @escaping Clock = { Date() }, present: @Sendable (DeviceAuthorization) async throws -> Void) async throws -> LocalOAuthCredential {
        let provider = provider.replacingOccurrences(of:"_",with:"-"); guard Tables.data["providers"].has(provider) else { throw NotConfiguredError("unknown login provider") }
        guard provider == "xai" else { let definition = Tables.data["providers"][provider]; throw UnsupportedFeatureError("\(provider): \(definition["access"]["login_hint"].or(definition["console_url"]).s)",metadata:["provider":j(provider)]) }
        let device = try await startXAIDeviceLogin(transport:transport); try await present(device)
        let credential = try await pollXAIDeviceLogin(device,transport:transport,clock:clock), store = CredentialFileStore(path:path,env:env)
        try await withFileLock(store.path,env:env) {
            var data = store.readAll(), entry = data["xai"].isObject ? data["xai"] : [:]
            entry = entry.merging(["type":"oauth","access":j(credential.accessToken),"refresh":credential.refreshToken.map(j) ?? .null,"expires":credential.expiresAt.map { j(Int($0.timeIntervalSince1970*1000)) } ?? .null]); data["xai"] = entry; try writePrivateJSONAtomic(store.path,value:data)
        }
        return try loadOAuth(provider:"xai",path:store.path,env:env)
    }
}
