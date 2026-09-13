import Foundation

private func checkedDeadline(pollEvery: TimeInterval, timeout: TimeInterval?) throws -> ContinuousClock.Instant? {
    guard pollEvery.isFinite && pollEvery > 0, timeout == nil || (timeout!.isFinite && timeout! >= 0) else { throw ValueError("invalid job polling interval or timeout") }
    return timeout.map { ContinuousClock.now.advanced(by:.seconds($0)) }
}
private func pollDelay(_ seconds: TimeInterval, _ deadline: ContinuousClock.Instant?) async throws {
    try Task.checkCancellation(); let now = ContinuousClock.now
    if let deadline, now >= deadline { throw TimeoutError("job wait timed out") }
    let target = min(now.advanced(by:.seconds(seconds)),deadline ?? now.advanced(by:.seconds(seconds)))
    try await ContinuousClock().sleep(until:target)
    if let deadline, ContinuousClock.now >= deadline { throw TimeoutError("job wait timed out") }
}
public actor BatchJob {
    let lm: ProviderLM
    public private(set) var info: BatchJobInfo
    public nonisolated let id: String
    init(lm: ProviderLM, info: BatchJobInfo) { self.lm = lm; self.info = info; id = info.id }
    public var done: Bool { info.done }
    public var status: BatchStatus { info.status }
    @discardableResult public func refresh() async throws -> BatchJobInfo { info = try await lm.batchStatus(id); return info }
    @discardableResult public func cancel() async throws -> BatchJobInfo { info = try await lm.batchCancel(id); return info }
    public func results() async throws -> [BatchEntry] { try await lm.batchResults(id) }
    @discardableResult public func wait(pollEvery: TimeInterval = 2, timeout: TimeInterval? = nil) async throws -> BatchJobInfo {
        let deadline = try checkedDeadline(pollEvery:pollEvery,timeout:timeout)
        while !info.done { try await pollDelay(pollEvery,deadline); try await refresh() }; return info
    }
}
public actor VideoJob {
    let lm: ProviderLM
    public private(set) var info: VideoJobInfo
    public nonisolated let id: String
    init(lm: ProviderLM, info: VideoJobInfo) { self.lm = lm; self.info = info; id = info.id }
    public var done: Bool { info.done }
    public var status: VideoStatus { info.status }
    @discardableResult public func refresh() async throws -> VideoJobInfo { info = try await lm.videoStatus(id); return info }
    public func result() async throws -> VideoPart { try await lm.videoResult(id) }
    @discardableResult public func wait(pollEvery: TimeInterval = 2, timeout: TimeInterval? = nil) async throws -> VideoJobInfo {
        let deadline = try checkedDeadline(pollEvery:pollEvery,timeout:timeout)
        while !info.done { try await pollDelay(pollEvery,deadline); try await refresh() }; return info
    }
}
extension ProviderLM {
    public func batch(_ request: BatchRequest) async throws -> BatchJob { try await BatchJob(lm:self,info:batchSubmit(request)) }
    public func batch(_ requests: [Request], label: String? = nil, extensions: JSONValue? = nil) async throws -> BatchJob { try await batch(BatchRequest(requests:requests,label:label,extensions:extensions)) }
    public func batchJob(_ id: String) async throws -> BatchJob { try await BatchJob(lm:self,info:batchStatus(id)) }
    public func batches(limit: Int = 20) async throws -> [BatchJob] { try await batchList(limit:limit).map { BatchJob(lm:self,info:$0) } }
    public func videoGenerate(_ request: VideoGenerationRequest) async throws -> VideoJob { try await VideoJob(lm:self,info:submitVideo(request)) }
    public func videoJob(_ id: String) async throws -> VideoJob { try await VideoJob(lm:self,info:videoStatus(id)) }
    public func videoJobs(limit: Int = 20, model: String? = nil) async throws -> [VideoJob] { try await listVideos(limit:limit,model:model).map { VideoJob(lm:self,info:$0) } }
}
extension CachedPrefix {
    public var id: String? { resource?.id }
    public var expiresAt: String? { resource?.expiresAt }
    public var cacheConfig: CacheConfig { get throws { try CacheConfig(prefixUntilIndex:prefix.messages.count-1,resource:id) } }
    public func request(_ messages: [Message], config: Config = .defaultValue) throws -> Request {
        guard !messages.isEmpty else { throw ValueError("suffix must contain messages") }; guard config.cache == nil else { throw ValueError("CachedPrefix decides config.cache") }
        return try prefix.with(messages:prefix.messages+messages,config:Config(json:config.rawValue.with("cache",cacheConfig.rawValue)))
    }
    public func request(_ text: String, config: Config = .defaultValue) throws -> Request { try request([Message.user(text)],config:config) }
    public func request(_ suffix: Request) throws -> Request {
        guard suffix.model == prefix.model && suffix.system == nil && suffix.tools.isEmpty else { throw ValueError("suffix must use prefix model and cannot redefine system or tools") }; return try request(suffix.messages,config:suffix.config)
    }
}
public func openAIChatModelString(_ model: String) throws -> String {
    if model.contains(":") { return model }; let parts = model.split(separator:"/",maxSplits:1,omittingEmptySubsequences:false)
    guard parts.count == 2 && !parts[1].isEmpty else { return model }; let provider = Tables.data["litellm_prefixes"][String(parts[0])]
    guard provider.isString else { throw UnknownModelError("unknown migration provider; use provider:model",metadata:["model":j(model)]) }; return provider.s+":"+parts[1]
}
extension LMRouter {
    public nonisolated func resolveOpenAIChat(_ model: String) throws -> Resolution { let result = try resolve(openAIChatModelString(model)); return result.source == "rule" && result.provider == "openai" ? try resolve("openai-chat:"+result.model) : result }
    public func requestFromOpenAIChat(_ body: JSONValue) throws -> (request: Request, adapter: ProviderLM) {
        let clientKeys = ["api_key","api_base","base_url","timeout","num_retries","max_retries","headers","extra_headers","cache","caching","drop_params","api_version","organization","client"]
        if let bad = clientKeys.first(where:body.has) { throw NotConfiguredError("\(bad) configures the client; use RouterConfig") }
        guard body["model"].isString else { throw UnknownModelError("model must be a string") }
        let result = try resolveOpenAIChat(body["model"].s), adapter = try lm(result.provider+":"+result.model), wire = body.with("model",j(result.model))
        return (try adapter.dialect == "openai-chat" ? adapter.requestFromOpenAIChat(wire) : LM15.requestFromOpenAIChat(wire),adapter)
    }
    public func completeFromOpenAIChat(_ body: JSONValue) async throws -> Response { if body["stream"].b { throw ValueError("use streamFromOpenAIChat or responseStreamFromOpenAIChat for streaming") }; let (request,adapter) = try requestFromOpenAIChat(body); return try await adapter.complete(request) }
    public func streamFromOpenAIChat(_ body: JSONValue) throws -> AsyncThrowingStream<StreamEvent,any Error> { let (request,adapter) = try requestFromOpenAIChat(body); return adapter.stream(request) }
    public func responseStreamFromOpenAIChat(_ body: JSONValue) throws -> ResponseStream { let (request,adapter) = try requestFromOpenAIChat(body); return adapter.responseStream(request) }
    public func generateImage(_ request: ImageGenerationRequest) async throws -> ImageGenerationResponse { let result = try resolve(request.model); return try await lm(request.model).generateImage(ImageGenerationRequest(json:request.rawValue.with("model",j(result.model)))) }
    public func generateSpeech(_ request: SpeechGenerationRequest) async throws -> SpeechGenerationResponse { let result = try resolve(request.model); return try await lm(request.model).generateSpeech(SpeechGenerationRequest(json:request.rawValue.with("model",j(result.model)))) }
    public func videoGenerate(_ request: VideoGenerationRequest) async throws -> VideoJob { let result = try resolve(request.model); return try await lm(request.model).videoGenerate(VideoGenerationRequest(json:request.rawValue.with("model",j(result.model)))) }
    public func cache(_ prefix: Request, ttlSeconds: Int? = nil, label: String? = nil) async throws -> CachedPrefix { let result = try resolve(prefix.model); return try await lm(prefix.model).cache(prefix.with(model:result.model),ttlSeconds:ttlSeconds,label:label) }
    public func live(_ config: LiveConfig, connect: LiveConnector = { try await connectLiveSocket($0) }) async throws -> LiveSession { let result = try resolve(config.model); return try await lm(config.model).live(LiveConfig(json:config.rawValue.with("model",j(result.model))),connect:connect) }
    public func batch(_ request: BatchRequest) async throws -> BatchJob {
        guard let model = request.model ?? request.requests.first?.model else { throw ValueError("batch must contain requests") }; let result = try resolve(model)
        let requests = try request.requests.map { entry in let routed = try resolve(entry.model); guard routed.provider == result.provider else { throw ValueError("one batch cannot span providers") }; return try entry.with(model:routed.model) }
        return try await lm(result.provider+":"+result.model).batch(BatchRequest(model:result.model,requests:requests,label:request.label,extensions:request.extensions))
    }
}
