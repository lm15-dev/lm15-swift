import XCTest
import Foundation
@testable import LM15

final class AuthTests: XCTestCase, @unchecked Sendable {
    func testConcurrentRefreshAtomicPermissionsAndUnknownFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm15-auth-"+UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath:root) }
        let path = root+"/credentials.json", env = ["LM15_LOCK_DIR":root+"/locks"], now = Date(timeIntervalSince1970:1_800_000_000), count = Counter()
        try Auth.writePrivateJSONAtomic(path,value:["keep":["nested":true],"claudeAiOauth":["accessToken":"old","refreshToken":"refresh","expiresAt":0,"scopes":["keep-me"]]])
        let transport = MockHTTP { request in
            let attempt = await count.increment(); XCTAssertEqual(attempt,1)
            XCTAssertEqual(try J.parse(request.body)["refresh_token"],"refresh")
            try await Task.sleep(for:.milliseconds(40)); return try HTTPResponse(json:["access_token":"new","refresh_token":"rotated","expires_in":3600])
        }
        let tokens = try await withThrowingTaskGroup(of:String.self) { group in
            for _ in 0..<4 { group.addTask { try await Auth.getOAuth(provider:"claude-code",path:path,env:env,clock:{now},transport:transport).accessToken } }
            var tokens: [String] = []; for try await token in group { tokens.append(token) }; return tokens
        }
        XCTAssertEqual(tokens,Array(repeating:"new",count:4)); let calls = await count.value; XCTAssertEqual(calls,1)
        let data = Auth.readJSON(path,env:env)!; XCTAssertEqual(data["keep"]["nested"],true); XCTAssertEqual(data["claudeAiOauth"]["scopes"],["keep-me"])
        let attrs = try FileManager.default.attributesOfItem(atPath:path); XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testLockTimeoutAndSymlinkRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm15-lock-"+UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath:root) }
        let path = root+"/credential", env = ["LM15_LOCK_DIR":root+"/locks"]
        try await Auth.withFileLock(path,env:env) {
            do { _ = try await Auth.withFileLock(path,timeout:0.01,env:env) { 1 }; XCTFail("reentrant lock unexpectedly succeeded") } catch is LockTimeoutError {}
        }
        let lock = Auth.lockPath(for:path,env:env); try FileManager.default.removeItem(atPath:lock)
        try FileManager.default.createSymbolicLink(atPath:lock,withDestinationPath:root+"/elsewhere")
        do { _ = try await Auth.withFileLock(path,env:env) { 1 }; XCTFail("symlink lock accepted") } catch is NotConfiguredError {}
    }
    func testRefreshFailureDoesNotOverwriteOrDisclose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lm15-failure-"+UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath:root) }; let path = root+"/auth", env = ["LM15_LOCK_DIR":root+"/locks"]
        try Auth.writePrivateJSONAtomic(path,value:["xai":["access":"sentinel-old-secret","refresh":"sentinel-refresh-secret","expires":0]])
        let before = try Data(contentsOf:URL(fileURLWithPath:path)), transport = MockHTTP { _ in try HTTPResponse(status:401,json:["error":"sentinel-server-secret"]) }
        do { _ = try await Auth.getOAuth(provider:"xai",path:path,env:env,transport:transport); XCTFail("refresh accepted") }
        catch { XCTAssertTrue(error is AuthError); XCTAssertFalse(String(describing:error).contains("sentinel")) }
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)),before)
    }
    func testNativeProcessArgumentsTimeoutAndCancellation() async throws {
        #if os(Linux) || os(macOS)
        let text = try await CredentialProcess.run(executable:"/usr/bin/printf",arguments:["%s","literal $(no-shell); 東京"],environment:[:],timeout:2)
        XCTAssertEqual(text,"literal $(no-shell); 東京")
        XCTAssertEqual(try shellWords("helper 'argument with space' \"quoted\""),["helper","argument with space","quoted"])
        let start = ContinuousClock.now
        do { _ = try await CredentialProcess.run(executable:"/bin/sleep",arguments:["10"],environment:[:],timeout:0.06); XCTFail("timeout ignored") } catch is AuthError {}
        XCTAssertLessThan(start.duration(to:.now),.seconds(2))
        let task = Task { try await CredentialProcess.run(executable:"/bin/sleep",arguments:["10"],environment:[:],timeout:20) }
        try await Task.sleep(for:.milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("cancellation ignored") } catch is CancellationError {}
        #endif
    }
    func testCloudCredentialCacheCoalescesAndExpires() async throws {
        let cache = CredentialCache(), count = Counter(), now = Date(timeIntervalSince1970:1_800_000_000)
        let fetch: @Sendable () async throws -> Credential = { _ = await count.increment(); try await Task.sleep(for:.milliseconds(30)); return .bearerToken(try BearerToken(value:"ephemeral",expiresAt:now.addingTimeInterval(3600))) }
        try await withThrowingTaskGroup(of:Credential.self) { group in for _ in 0..<5 { group.addTask { try await cache.resolve(now:now,operation:fetch) } }; for try await _ in group {} }
        _ = try await cache.resolve(now:now,operation:fetch); var calls = await count.value; XCTAssertEqual(calls,1)
        _ = try await cache.resolve(now:now.addingTimeInterval(3400),operation:fetch); calls = await count.value; XCTAssertEqual(calls,2)
    }
    func testAWSWebIdentityParsesNamespacedSTSAndNoUnsignedFallback() async throws {
        let transport = MockHTTP { request in
            XCTAssertEqual(request.url,"https://sts.eu-west-1.amazonaws.com/"); XCTAssertTrue(String(decoding:request.body,as:UTF8.self).contains("WebIdentityToken=subject"))
            return HTTPResponse(body:Data("<sts:AssumeRoleWithWebIdentityResponse xmlns:sts=\"urn:sts\"><sts:Credentials><sts:AccessKeyId>access</sts:AccessKeyId><sts:SecretAccessKey>secret</sts:SecretAccessKey><sts:SessionToken>session</sts:SessionToken><sts:Expiration>2030-01-01T00:00:00Z</sts:Expiration></sts:Credentials></sts:AssumeRoleWithWebIdentityResponse>".utf8))
        }
        let chain = CloudChain(provider:"bedrock-chat",env:["AWS_REGION":"eu-west-1","AWS_ROLE_ARN":"arn:role","AWS_WEB_IDENTITY_TOKEN_FILE":"/token","AWS_EC2_METADATA_DISABLED":"true"],files:["/token":"subject\n"],transport:transport)
        let credential = try await chain.acquire(); guard case .aws(let aws) = credential else { return XCTFail("expected AWS credentials") }
        XCTAssertEqual(aws.accessKeyId,"access"); XCTAssertEqual(aws.sessionToken,"session")
        XCTAssertThrowsError(try CloudChain(provider:"bedrock-chat",env:["AWS_CONTAINER_CREDENTIALS_FULL_URI":"http://untrusted.test/credentials"],files:[:]).containerURL())
    }
    func testAzureAndGoogleTokenChainsUseInjectedTransport() async throws {
        let azure = CloudChain(provider:"azure",env:["AZURE_RESOURCE":"unit","AZURE_TENANT_ID":"tenant","AZURE_CLIENT_ID":"client","AZURE_CLIENT_SECRET":"secret"],files:[:],settings:["resource":"unit"],transport:MockHTTP { request in
            XCTAssertTrue(request.url.contains("tenant/oauth2/v2.0/token")); XCTAssertTrue(String(decoding:request.body,as:UTF8.self).contains("client_secret=secret")); return try HTTPResponse(json:["access_token":"azure-token","expires_in":3600])
        })
        let a = try await azure.acquire(); XCTAssertEqual(a.rawValue["value"],"azure-token")
        let adc: J = ["type":"authorized_user","client_id":"client","client_secret":"secret","refresh_token":"refresh","quota_project_id":"project"]
        let google = CloudChain(provider:"vertex",env:["GOOGLE_APPLICATION_CREDENTIALS":"/adc","NO_GCE_CHECK":"true"],files:["/adc":try adc.jsonString()],transport:MockHTTP { request in
            XCTAssertTrue(String(decoding:request.body,as:UTF8.self).contains("refresh_token=refresh")); return try HTTPResponse(json:["access_token":"google-token","expires_in":3600])
        })
        let g = try await google.acquire(); XCTAssertEqual(g.rawValue["value"],"google-token")
    }
    func testPKCEKnownChallengeAndDeviceSlowDown() async throws {
        XCTAssertEqual(try Auth.pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let pair = try Auth.generatePKCE(); XCTAssertEqual(pair.challenge,try Auth.pkceChallenge(pair.verifier)); XCTAssertFalse(pair.description.contains(pair.verifier))
        let count = Counter(), device = try Auth.DeviceAuthorization(json:["user_code":"public","device_code":"private","verification_uri":"https://auth.x.ai/activate","expires_in":100,"interval":1])
        let transport = MockHTTP { _ in switch await count.increment() { case 1: return try HTTPResponse(status:400,json:["error":"authorization_pending"]); case 2: return try HTTPResponse(status:400,json:["error":"slow_down"]); default: return try HTTPResponse(json:["access_token":"done","refresh_token":"refresh","expires_in":3600]) } }
        let credential = try await Auth.pollXAIDeviceLogin(device,transport:transport,sleep:{ _ in })
        XCTAssertEqual(credential.accessToken,"done"); XCTAssertFalse(device.description.contains("private"))
        XCTAssertThrowsError(try Auth.DeviceAuthorization(json:["user_code":"code","device_code":"device","verification_uri":"https://user:password@auth.test","expires_in":90]))
    }
}
