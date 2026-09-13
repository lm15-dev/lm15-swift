import XCTest
import Foundation
@testable import LM15

actor Counter {
    var value = 0
    func increment() -> Int { value += 1; return value }
}
struct MockHTTP: HTTPTransport {
    let handler: @Sendable (TransportRequest) async throws -> HTTPResponse
    var streaming: (@Sendable (TransportRequest) async throws -> HTTPByteStream)? = nil
    func send(_ request: TransportRequest) async throws -> HTTPResponse { try await handler(request) }
    func stream(_ request: TransportRequest) async throws -> HTTPByteStream { if let streaming { return try await streaming(request) }; let response = try await send(request); return HTTPByteStream(response:response,chunks:AsyncThrowingStream { $0.yield(response.body); $0.finish() }) }
}
final class Signal: @unchecked Sendable {
    let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class CoreTests: XCTestCase, @unchecked Sendable {
    func testTypedRoundtripOpaqueNumbersAndUnicode() throws {
        let opaque = try JSONValue.parse(#"{"number":1.0,"integer":1,"nil":null,"empty":[],"text":"é 🦀 東京","large":9223372036854775807}"#)
        let part = try ToolCallPart(id:"call",name:"lookup",input:opaque)
        let roundtrip = try ToolCallPart.fromJSON(part.toJSONString())
        XCTAssertEqual(roundtrip,part); XCTAssertEqual(roundtrip.input,opaque)
        XCTAssertTrue(try part.toJSONString().contains("1.0"))
        XCTAssertNotEqual(JSONValue.int(1),JSONValue.number(1))
        XCTAssertThrowsError(try Config(temperature:.nan)); XCTAssertThrowsError(try ImagePart(data:"!"))
        let message = try Message.user("hello")
        XCTAssertEqual(try JSONDecoder().decode(Message.self,from:JSONEncoder().encode(message)),message)
    }
    func testLargeCanonicalIntegersNeverRoundOrOverflow() throws {
        let usage = try Usage(inputTokens:Int.max)
        XCTAssertEqual(usage.inputTokens,Int.max)
        XCTAssertEqual(try Usage.fromJSON(usage.toJSONString()).inputTokens,Int.max)
        XCTAssertThrowsError(try Usage(inputTokens:Int.max,outputTokens:1))
        let budget = try Reasoning(effort:.high,thinkingBudget:9_007_199_254_740_993)
        XCTAssertEqual(budget.thinkingBudget,9_007_199_254_740_993)
    }
    func testTypedInitializersAndDecoderAgree() throws {
        let request = try Request(model:"gpt-4.1",messages:[.user("What is 2+2?")],tools:[.function(FunctionTool(name:"sum",parameters:["type":"object","properties":[:]]))],config:Config(temperature:0.2,reasoning:Reasoning(effort:.low)))
        XCTAssertEqual(try Request.fromJSON(request.toJSONString()),request)
        XCTAssertThrowsError(try Reasoning(effort:.off,thinkingBudget:8))
        XCTAssertThrowsError(try Part(json:["type":"something_new"]))
        XCTAssertEqual(try ApiKey(value:"private").description,"ApiKey([REDACTED])")
    }
    func testCacheSuffixRetainsPrefixAndRestrictsOverrides() throws {
        let prefix = try Request(model:"gemini-2.5-flash",messages:[.user("large reference")],system:"Be precise")
        let cached = try CachedPrefix(prefix:prefix,resource:CacheInfo(id:"cachedContents/42",model:prefix.model))
        let request = try cached.request("Summarize it")
        XCTAssertEqual(request.messages.count,2); XCTAssertEqual(request.config.cache?.resource,"cachedContents/42")
        XCTAssertEqual(request.config.cache?.prefixUntilIndex,0); XCTAssertEqual(request.system,prefix.system)
        XCTAssertThrowsError(try cached.request(Request(model:"different",messages:[.user("x")])))
        XCTAssertThrowsError(try cached.request("x",config:Config(cache:CacheConfig())))
    }
    func testCredentialCallbackResolvesOncePerRequest() async throws {
        let count = Counter()
        let lm = try OpenAIChatLM(credentialProvider:{ .apiKey(try ApiKey(value:"key-\(await count.increment())")) },env:[:])
        let request = try Request(model:"gpt-4.1",messages:[.user("Hi")])
        let first = try await lm.buildRequest(request), second = try await lm.buildRequest(request)
        XCTAssertEqual(first.headers["authorization"],"Bearer key-1"); XCTAssertEqual(second.headers["authorization"],"Bearer key-2")
        let total = await count.value; XCTAssertEqual(total,2)
        let empty = try OpenAIChatLM(apiKey:"",env:["OPENAI_API_KEY":"must-not-fallback"])
        do { _ = try await empty.buildRequest(request); XCTFail("empty explicit key accepted") } catch is NotConfiguredError {}
    }
    func testRouterMigrationAndMixedBatchRejection() async throws {
        let router = try LMRouter(config:RouterConfig(env:[:],apiKeys:["openai":"placeholder","anthropic":"placeholder"]))
        XCTAssertEqual(try router.resolveOpenAIChat("gpt-4.1").provider,"openai-chat")
        XCTAssertEqual(try openAIChatModelString("anthropic/claude-sonnet-4-5"),"anthropic:claude-sonnet-4-5")
        let (request,adapter) = try await router.requestFromOpenAIChat(["model":"gpt-4.1","messages":[["role":"user","content":"hi"]]])
        XCTAssertEqual(request.model,"gpt-4.1"); XCTAssertEqual(adapter.provider,"openai-chat")
        do { _ = try await router.batch(BatchRequest(requests:[Request(model:"openai:gpt-4.1",messages:[.user("a")]),Request(model:"anthropic:claude-sonnet-4-5",messages:[.user("b")])])); XCTFail("mixed batch accepted") } catch is ValueError {}
    }
    func testSSEFragmentationLimitsAndUsageUnknowns() throws {
        let wire = Data("event: message\r\ndata: {\"value\":\"🦀\"}\r\ndata: second\r\n\r\n".utf8)
        var parser = SSEParser(), events: [SSEEvent] = []
        for byte in wire { events += try parser.feed(Data([byte])) }
        XCTAssertEqual(events.count,1); XCTAssertEqual(events.first?.data,"{\"value\":\"🦀\"}\nsecond")
        var small = SSEParser(maxLineBytes:3); XCTAssertThrowsError(try small.feed(Data("toolong".utf8)))
        let usage = try sumUsage(Usage(inputTokens:2,outputTokens:3),Usage(inputTokens:5))
        XCTAssertEqual(usage.inputTokens,7); XCTAssertNil(usage.outputTokens); XCTAssertNil(usage.totalTokens)
    }
    func testLiveTurnToolBoundaryAndAudioConsistency() throws {
        let events: [LiveServerEvent] = try [.text(LiveServerTextEvent(text:"Hi")),.audio(LiveServerAudioEvent(data:"AQI=",mediaType:"audio/pcm")),.usage(LiveServerUsageEvent(usage:Usage(inputTokens:3))),.toolCall(LiveServerToolCallEvent(id:"call",name:"lookup",input:["id":7]))]
        let turn = try materializeTurn(events); XCTAssertEqual(turn.endedBy,"tool_call"); XCTAssertFalse(turn.ok); XCTAssertEqual(turn.audio,Data([1,2])); XCTAssertEqual(turn.toolCalls.first?.name,"lookup")
        XCTAssertThrowsError(try materializeTurn(events+[.audio(LiveServerAudioEvent(data:"AwQ=",mediaType:"audio/wav"))]))
    }
}
