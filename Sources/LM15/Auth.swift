import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@_silgen_name("flock") private func lm15_flock(_ fd: Int32, _ operation: Int32) -> Int32
public enum Environment {
    public static var current: [String:String] {
        #if os(Linux)
        var out: [String:String] = [:], i = 0
        while let pointer = environ[i] { let entry = String(cString:pointer); if let split = entry.firstIndex(of:"=") { out[String(entry[..<split])] = String(entry[entry.index(after:split)...]) }; i += 1 }; return out
        #else
        return ProcessInfo.processInfo.environment
        #endif
    }
}
public struct LocalOAuthCredential: Sendable, CustomStringConvertible {
    public let accessToken: String, refreshToken: String?, expiresAt: Date?, accountID: String?, path: String
    public var description: String { "LocalOAuthCredential([REDACTED])" }
    public func expired(at now: Date = Date()) -> Bool { expiresAt.map { now >= $0 } ?? false }
    public func usable(at now: Date = Date()) -> Bool { !expired(at:now) || refreshToken != nil }
}
public enum Auth {
    public static let refreshSkew: TimeInterval = 300
    static let tokenEndpoints = ["claude-code":("https://platform.claude.com/v1/oauth/token","9d1c250a-e61b-44d5-88ed-5944d1962f5e"),"openai-codex":("https://auth.openai.com/oauth/token","app_EMoamEEZ73f0CkXaXp7hrann"),"xai":("https://auth.x.ai/oauth2/token","b1a00492-073a-47ea-816f-4c329264a828")]
    public static func expand(_ path: String, env: [String:String] = Environment.current) -> String { path.hasPrefix("~/") ? (env["HOME"] ?? NSHomeDirectory())+"/"+path.dropFirst(2) : path }
    public static func defaultCredentialsPath(env: [String:String] = Environment.current) -> String { expand(env["LM15_CREDENTIALS_PATH"] ?? (env["XDG_CONFIG_HOME"] ?? "~/.config")+"/lm15/credentials.json",env:env) }
    public static func lockPath(for target: String, env: [String:String] = Environment.current) -> String {
        let canonical = URL(fileURLWithPath:expand(target,env:env)).standardizedFileURL.resolvingSymlinksInPath().path
        let dir = expand(env["LM15_LOCK_DIR"] ?? (env["XDG_CACHE_HOME"] ?? "~/.cache")+"/lm15/locks",env:env)
        return dir+"/"+String(sha256(Data(canonical.utf8)).prefix(32))+".lock"
    }
    public static func withFileLock<T: Sendable>(_ target: String, timeout: TimeInterval = 60, env: [String:String] = Environment.current, operation: @Sendable () async throws -> T) async throws -> T {
        guard timeout.isFinite && timeout >= 0 else { throw ValueError("lock timeout must be finite and nonnegative") }
        let path = lockPath(for:target,env:env), dir = URL(fileURLWithPath:path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = open(path,O_RDWR|O_CREAT|O_NOFOLLOW,0o600); guard fd >= 0 else { throw NotConfiguredError("credential lock could not be opened") }; defer { _ = close(fd) }
        var info = stat(); guard fstat(fd,&info) == 0 && (info.st_mode & S_IFMT) == S_IFREG else { throw NotConfiguredError("credential lock must be a regular file") }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by:.seconds(timeout))
        while lm15_flock(fd,LOCK_EX|LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR { throw NotConfiguredError("credential file lock failed") }
            if clock.now >= deadline { throw LockTimeoutError("credential file lock timed out; do not delete the lock file",metadata:["path":j(target),"lock_path":j(path)]) }
            try await Task.sleep(for:.milliseconds(50))
        }
        defer { _ = lm15_flock(fd,LOCK_UN) }; return try await operation()
    }
    public static func writePrivateJSONAtomic(_ target: String, value: JSONValue) throws {
        let dir = URL(fileURLWithPath:target).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let temp = dir+"/.lm15-"+UUID().uuidString+".tmp", bytes = try value.jsonData()
        let fd = open(temp,O_WRONLY|O_CREAT|O_EXCL,0o600); guard fd >= 0 else { throw NotConfiguredError("credential temporary file could not be created") }
        defer { _ = close(fd); _ = unlink(temp) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count { let n = write(fd,buffer.baseAddress!.advanced(by:offset),bytes.count-offset); if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw NotConfiguredError("credential file write failed") }; offset += n }
        }
        guard fsync(fd) == 0 && rename(temp,target) == 0 else { throw NotConfiguredError("credential file atomic replacement failed") }
        let directory = open(dir,O_RDONLY); if directory >= 0 { defer { _ = close(directory) }; guard fsync(directory) == 0 else { throw NotConfiguredError("credential directory sync failed") } }
    }
    static func read(_ path: String?, env: [String:String], files: [String:String]?) -> String? {
        guard let path else { return nil }; let p = expand(path,env:env)
        if let files { return files[p] ?? files[path] ?? files.first { expand($0.key,env:env) == p }?.value }
        return try? String(contentsOfFile:p,encoding:.utf8)
    }
    public static func readJSON(_ path: String, env: [String:String] = Environment.current, files: [String:String]? = nil) -> JSONValue? { guard let text = read(path,env:env,files:files), let value = try? J.parse(text), value.isObject else { return nil }; return value }
    static func jwtPayload(_ token: String) -> J { let parts = token.split(separator:".",omittingEmptySubsequences:false); guard parts.count > 1, let data = decodeBase64URL(String(parts[1])), let parsed = try? J.parse(data) else { return [:] }; return parsed }
    static func accountID(_ token: String) -> String? { let id = jwtPayload(token)["https://api.openai.com/auth"]["chatgpt_account_id"]; return id.isString ? id.s : nil }
    static func storePaths(_ provider: String, path: String?, env: [String:String]) -> [String] {
        if let path { return [expand(path,env:env)] }
        let paths = provider == "claude-code" ? ["~/.claude/.credentials.json"] : provider == "openai-codex" ? ["~/.codex/auth.json"] : provider == "xai" ? [defaultCredentialsPath(env:env),"~/.pi/agent/auth.json"] : []
        return paths.map { expand($0,env:env) }
    }
    public static func loadOAuth(provider: String, path: String? = nil, env: [String:String] = Environment.current, files: [String:String]? = nil) throws -> LocalOAuthCredential {
        for file in storePaths(provider,path:path,env:env) {
            guard let data = readJSON(file,env:env,files:files) else { continue }
            let section = ["claude-code":"claudeAiOauth","openai-codex":"tokens","xai":"xai"][provider] ?? "", raw = data[section]; if !raw.isObject { continue }
            let token: J, refresh: J; var expiry: Date?, account: String?
            switch provider {
            case "claude-code": token = raw["accessToken"]; refresh = raw["refreshToken"]; if raw["expiresAt"].isNumber { expiry = Date(timeIntervalSince1970:raw["expiresAt"].d/1000) }
            case "openai-codex": token = raw["access_token"]; refresh = raw["refresh_token"]; let exp = jwtPayload(token.s)["exp"]; if exp.isNumber { expiry = Date(timeIntervalSince1970:exp.d-refreshSkew) }; account = raw["account_id"].isString ? raw["account_id"].s : accountID(token.s)
            default: token = raw["access"]; refresh = raw["refresh"]; if raw["expires"].isNumber { expiry = Date(timeIntervalSince1970:raw["expires"].d/1000) }
            }
            if token.isString && !token.empty { return LocalOAuthCredential(accessToken:token.s,refreshToken:refresh.isString && !refresh.empty ? refresh.s : nil,expiresAt:expiry,accountID:account,path:file) }
        }
        throw NotConfiguredError("\(provider): no usable local credential file. \(Tables.data["providers"][provider]["access"]["login_hint"].s)",metadata:["provider":j(provider)])
    }
    public static func getOAuth(provider: String, path: String? = nil, env: [String:String] = Environment.current, clock: @escaping Clock = { Date() }, transport: any HTTPTransport = URLSessionTransport(), refresh: Bool = true) async throws -> LocalOAuthCredential {
        let initial = try loadOAuth(provider:provider,path:path,env:env)
        if !initial.expired(at:clock()) { return initial }
        guard refresh && initial.refreshToken != nil else { throw AuthError("\(provider): OAuth token expired") }
        return try await withFileLock(initial.path,env:env) {
            let current = try loadOAuth(provider:provider,path:initial.path,env:env); if !current.expired(at:clock()) { return current }
            guard let refreshToken = current.refreshToken, let endpoint = tokenEndpoints[provider] else { throw AuthError("expired credential has no refresh token") }
            let payload: J = ["grant_type":"refresh_token","client_id":j(endpoint.1),"refresh_token":j(refreshToken)], json = provider == "claude-code", d: J
            do {
                let req = try TransportRequest(method:"POST",url:endpoint.0,headers:["content-type":json ? "application/json" : "application/x-www-form-urlencoded","accept":"application/json"],body:json ? payload.jsonData() : formData(payload))
                let res = try await transport.send(req); d = try res.json()
                guard (200..<300).contains(res.status), d["access_token"].isString, !d["access_token"].empty else { throw AuthError("refresh failed") }
                if json && (!d["refresh_token"].isString || !d["expires_in"].isNumber) { throw AuthError("refresh failed") }
            } catch is CancellationError { throw CancellationError() }
            catch { throw AuthError("\(provider): OAuth refresh failed") }
            var data = readJSON(current.path,env:env) ?? [:]; let section = ["claude-code":"claudeAiOauth","openai-codex":"tokens","xai":"xai"][provider]!
            var raw = data[section].isObject ? data[section] : [:]; let token = d["access_token"], nextRefresh = d["refresh_token"].or(j(refreshToken)), expiry = j(Int((clock().timeIntervalSince1970+d["expires_in"].or(3600).d-refreshSkew)*1000))
            switch provider {
            case "claude-code": raw = raw.merging(["accessToken":token,"refreshToken":nextRefresh,"expiresAt":expiry])
            case "openai-codex": raw = raw.merging(["access_token":token,"refresh_token":nextRefresh]); if d["id_token"].isString { raw["id_token"] = d["id_token"] }; if let account = accountID(token.s) { raw["account_id"] = j(account) }; data["auth_mode"] = data["auth_mode"].or("chatgpt"); data["last_refresh"] = j(isoDate(clock()))
            default: raw = raw.merging(["type":"oauth","access":token,"refresh":nextRefresh,"expires":expiry])
            }
            data[section] = raw; try writePrivateJSONAtomic(current.path,value:data); return try loadOAuth(provider:provider,path:current.path,env:env)
        }
    }
}
func formData(_ value: J) -> Data { Data(value.orderedEntries.filter { $0.value.present }.map { pathID($0.key)+"="+pathID($0.value.stringValue) }.joined(separator:"&").utf8) }
public struct CredentialFileStore: Sendable {
    public let path: String
    let env: [String:String]
    public init(path: String? = nil, env: [String:String] = Environment.current) { self.path = Auth.expand(path ?? Auth.defaultCredentialsPath(env:env),env:env); self.env = env }
    public func readAll() -> JSONValue { Auth.readJSON(path,env:env) ?? [:] }
    public func read(_ provider: String) -> JSONValue { readAll()[provider] }
    public func list() -> [String] { readAll().o.keys.sorted() }
    public func write(_ provider: String, credential: JSONValue) async throws { try await Auth.withFileLock(path,env:env) { try Auth.writePrivateJSONAtomic(path,value:readAll().with(provider,credential)) } }
    public func delete(_ provider: String) async throws { try await Auth.withFileLock(path,env:env) { try Auth.writePrivateJSONAtomic(path,value:readAll().without([provider])) } }
}
