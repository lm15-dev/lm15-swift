import Foundation

public struct RouteRule: Sendable, Equatable {
    public let prefix: String, provider: String, note: String?
    public init(prefix: String, provider: String, note: String? = nil) { self.prefix = prefix; self.provider = provider; self.note = note }
    public static let defaults: [RouteRule] = Tables.data["rules"].a.map { RouteRule(prefix:$0["prefix"].s,provider:$0["provider"].s,note:$0["note"].isNull ? nil : $0["note"].s) }
}
public struct Resolution: Sendable, Equatable, CustomStringConvertible {
    public let requested: String, model: String, provider: String, source: String
    public let rule: RouteRule?, envKey: String?, modelInfo: ModelInfo?
    public var description: String { "\(requested) -> \(provider):\(model) via \(source)" }
    public func toJSON() -> JSONValue { ["provider":j(provider),"model":j(model),"source":j(source)] }
}
public struct ModelRegistry: Sendable, Equatable {
    private var models: [ModelInfo]
    public init(_ models: [ModelInfo] = []) { self.models = models }
    public mutating func add(_ info: ModelInfo, replace: Bool = true) { if replace { models.removeAll { $0.id == info.id && $0.provider == info.provider } }; models.append(info) }
    public func list(provider: String? = nil) -> [ModelInfo] { models.filter { provider == nil || $0.provider == provider } }
    public func get(_ id: String, provider: String? = nil) -> ModelInfo? { models.first { $0.id == id && (provider == nil || $0.provider == provider) } }
}
public func resolveModel(_ model: String, registry: ModelRegistry? = nil, rules: [RouteRule] = RouteRule.defaults, env: [String:String] = Environment.current) throws -> Resolution {
    func unknown(_ message: String) -> UnknownModelError { UnknownModelError(message,metadata:["model":j(model)]) }
    func resolution(_ provider: String, _ resolved: String, _ source: String, _ rule: RouteRule? = nil, _ info: ModelInfo? = nil) -> Resolution {
        let key = Tables.data["providers"][provider]["access"]["env_keys"].a.map(\.s).first { !(env[$0] ?? "").isEmpty }
        return Resolution(requested:model,model:resolved,provider:provider,source:source,rule:rule,envKey:key,modelInfo:info)
    }
    guard !model.isEmpty else { throw unknown("model must be nonempty") }
    let parts = model.split(separator:":",maxSplits:1,omittingEmptySubsequences:false), head = String(parts[0]).replacingOccurrences(of:"_",with:"-")
    if parts.count == 2 && !parts[1].isEmpty && Tables.data["providers"].has(head) { return resolution(head,String(parts[1]),"prefix") }
    if let registry {
        var matches = registry.list().filter { $0.id == model || $0.aliases.contains(model) }
        let providers = matches.map(\.provider).reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } }
        if providers.count > 1 { throw AmbiguousModelError("model is offered by multiple providers; use provider:model",metadata:["model":j(model),"providers":arr(providers.map(j))]) }
        if !matches.isEmpty {
            let exact = matches.filter { $0.id == model }; if !exact.isEmpty { matches = exact }
            if matches.count > 1 { throw AmbiguousModelError("model matches multiple catalog entries",metadata:["model":j(model),"providers":arr(providers.map(j))]) }
            let info = matches[0], provider = info.provider.replacingOccurrences(of:"_",with:"-")
            guard Tables.data["providers"].has(provider) else { throw unknown("catalog provider has no adapter") }; return resolution(provider,info.id,"catalog",nil,info)
        }
    }
    for rule in rules where model.hasPrefix(rule.prefix) { let provider = rule.provider.replacingOccurrences(of:"_",with:"-"); guard Tables.data["providers"].has(provider) else { throw unknown("rule provider has no adapter") }; return resolution(provider,model,"rule",rule) }
    throw unknown("could not route model; use a known provider:model prefix")
}
public struct CredentialSource: Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let resolve: CredentialProvider
    public init(_ value: Credential) { resolve = { value } }
    public init(_ provider: @escaping CredentialProvider) { resolve = provider }
    public init(stringLiteral value: String) { resolve = { guard !value.isEmpty else { throw NotConfiguredError("explicit credential is empty") }; return .apiKey(try ApiKey(value:value)) } }
    public var description: String { "CredentialSource([REDACTED])" }
}
func apiKeysSource(_ providers: [String], _ provider: String) throws -> String? {
    let canonical = { (s: String) in s.replacingOccurrences(of:"_",with:"-") }
    var candidates = providers.filter { canonical($0) == provider }
    if candidates.isEmpty {
        let target = Tables.data["providers"][provider]["access"]["env_keys"]
        if !target.empty { candidates = providers.filter { Tables.data["providers"][canonical($0)]["access"]["env_keys"] == target } }
    }
    if candidates.count > 1 { throw NotConfiguredError("ambiguous credentials for \(provider); provide one exact entry") }; return candidates.first
}
public struct RouterConfig: Sendable, CustomStringConvertible {
    public let registry: ModelRegistry?, rules: [RouteRule], env: [String:String], apiKeys: [String:CredentialSource], baseURLs: [String:String], settings: [String:JSONValue], transport: any HTTPTransport
    public init(registry: ModelRegistry? = nil, rules: [RouteRule] = RouteRule.defaults, env: [String:String] = Environment.current, apiKeys: [String:CredentialSource] = [:], baseURLs: [String:String] = [:], settings: [String:JSONValue] = [:], transport: any HTTPTransport = URLSessionTransport()) throws {
        for keys in [Array(apiKeys.keys),Array(baseURLs.keys),Array(settings.keys)] { for key in keys { guard Tables.data["providers"].has(key.replacingOccurrences(of:"_",with:"-")) else { throw NotConfiguredError("unknown provider \(key)") } } }
        if Set(apiKeys.keys.map { $0.replacingOccurrences(of:"_",with:"-") }).count != apiKeys.count { throw NotConfiguredError("duplicate provider spellings in apiKeys") }
        self.registry = registry; self.rules = rules; self.env = env; self.apiKeys = apiKeys; self.baseURLs = baseURLs; self.settings = settings; self.transport = transport
    }
    public var description: String { "RouterConfig(providers: \(apiKeys.keys.sorted()))" }
}
public actor LMRouter {
    public nonisolated let config: RouterConfig
    private var adapters: [String:ProviderLM] = [:]
    public init(config: RouterConfig) { self.config = config }
    public init() throws { config = try RouterConfig() }
    public nonisolated func resolve(_ model: String) throws -> Resolution { try resolveModel(model,registry:config.registry,rules:config.rules,env:config.env) }
    public func lm(_ model: String) throws -> ProviderLM {
        let resolution = try resolve(model), provider = resolution.provider
        if let cached = adapters[provider] { return cached }
        let source = Tables.data["providers"][provider]["access"]["credential_policy"] == "oauth" ? nil : try apiKeysSource(Array(config.apiKeys.keys),provider)
        let key = source.flatMap { config.apiKeys[$0] }, base = config.baseURLs.first { $0.key.replacingOccurrences(of:"_",with:"-") == provider }?.value, settings = config.settings.first { $0.key.replacingOccurrences(of:"_",with:"-") == provider }?.value ?? [:]
        let adapter = try ProviderLM(provider:provider,credentialProvider:key?.resolve,baseURL:base,settings:settings,env:config.env,transport:config.transport); adapters[provider] = adapter; return adapter
    }
    public func complete(_ request: Request) async throws -> Response { let resolution = try resolve(request.model); return try await lm(request.model).complete(request.with(model:resolution.model)) }
    public func stream(_ request: Request) throws -> AsyncThrowingStream<StreamEvent, any Error> { let resolution = try resolve(request.model); return try lm(request.model).stream(request.with(model:resolution.model)) }
    public func responseStream(_ request: Request) throws -> ResponseStream { let resolution = try resolve(request.model); return try lm(request.model).responseStream(request.with(model:resolution.model)) }
}
