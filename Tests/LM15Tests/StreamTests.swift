import XCTest
import Foundation
@testable import LM15

func eventSequence(_ events: [StreamEvent], error: (any Error)? = nil) -> AsyncThrowingStream<StreamEvent,any Error> { AsyncThrowingStream { continuation in events.forEach { continuation.yield($0) }; continuation.finish(throwing:error) } }
func textEvents(_ text: String = "hello") throws -> [StreamEvent] { try [.start(StreamStartEvent(model:"unit")),.delta(StreamDeltaEvent(delta:.text(TextDelta(text:text,partIndex:0)))),.end(StreamEndEvent(finishReason:.stop,usage:Usage(inputTokens:2,outputTokens:1)))] }
final class FakeSocket: LiveSocket, @unchecked Sendable {
    let lock = NSLock()
    var frames: [Data], sent: [Data] = [], closed = false
    var waiter: CheckedContinuation<Data?,any Error>?
    init(_ values: [J]) throws { frames = try values.map { try $0.jsonData() } }
    func send(_ data: Data) async throws { try lock.withLock { if closed { throw TransportError("closed") }; sent.append(data) } }
    func receive() async throws -> Data? { try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if closed { lock.unlock(); continuation.resume(returning:nil) }
        else if !frames.isEmpty { let next = frames.removeFirst(); lock.unlock(); continuation.resume(returning:next) }
        else { waiter = continuation; lock.unlock() }
    } }
    func close() { lock.lock(); closed = true; let pending = waiter; waiter = nil; lock.unlock(); pending?.resume(returning:nil) }
    var isClosed: Bool { lock.withLock { closed } }
    var sentFrames: [J] { lock.withLock { sent.compactMap { try? J.parse($0) } } }
}
final class StreamTests: XCTestCase, @unchecked Sendable {
    func testTextIterationAssemblesResultAndPreservesCleanupFailure() async throws {
        let request = try Request(model:"unit",messages:[.user("hi")]), stream = ResponseStream(events:eventSequence(try textEvents(),error:TransportError("cleanup")),request:request)
        var text = ""; for try await chunk in stream { text += chunk }
        let response = try await stream.response(); XCTAssertEqual(text,"hello"); XCTAssertEqual(response.text,"hello"); XCTAssertEqual(response.usage.inputTokens,2)
        let cleanup = await stream.cleanupErrors; XCTAssertEqual(cleanup.count,1)
    }
    func testMissingEndAndAfterEndExposePartial() async throws {
        let request = try Request(model:"unit",messages:[.user("hi")]), events = try textEvents()
        let missing = ResponseStream(events:eventSequence(Array(events.prefix(2))),request:request)
        do { _ = try await missing.response(); XCTFail("missing end accepted") } catch let error as StreamAssemblyError { XCTAssertEqual(error.partialResponse?.text,"hello") }
        let extra = ResponseStream(events:eventSequence(events+[events[1]]),request:request)
        do { _ = try await extra.response(); XCTFail("event after end accepted") } catch is StreamAssemblyError {}
    }
    func testUnnamedToolDoesNotInventName() throws {
        let request = try Request(model:"unit",messages:[.user("hi")])
        let events: [StreamEvent] = try [.delta(StreamDeltaEvent(delta:.toolCall(ToolCallDelta(input:"{\"x\":1}",partIndex:0,id:"id")))),.end(StreamEndEvent(finishReason:.toolCall))]
        XCTAssertThrowsError(try materializeResponse(events,request:request)) { XCTAssertTrue($0 is StreamAssemblyError) }
    }
    func testEarlyCloseCancelsProviderAndSingleReaderIsEnforced() async throws {
        let source = AsyncThrowingStream<Data,any Error>.makeStream(), started = Counter(), cancelled = Signal()
        let transport = MockHTTP(handler:{ _ in HTTPResponse() },streaming:{ _ in _ = await started.increment(); return HTTPByteStream(response:HTTPResponse(),chunks:source.stream,cancel:{ cancelled.increment(); source.continuation.finish() }) })
        let lm = try OpenAIChatLM(apiKey:"placeholder",env:[:],transport:transport), request = try Request(model:"unit",messages:[.user("hi")]), stream = lm.responseStream(request)
        let reader = Task { try await stream.response() }
        for _ in 0..<100 { if await started.value > 0 { break }; try await Task.sleep(for:.milliseconds(2)) }
        do { _ = try await stream.response(); XCTFail("concurrent reader accepted") } catch is TypeError {}
        await stream.close()
        do { _ = try await reader.value; XCTFail("closed stream yielded result") } catch {}
        XCTAssertGreaterThan(cancelled.value,0)
    }
    func testTaskCancellationStopsProvider() async throws {
        let pair = AsyncThrowingStream<Data,any Error>.makeStream(), started = Counter(), cancelled = Signal()
        let transport = MockHTTP(handler:{ _ in HTTPResponse() },streaming:{ _ in _ = await started.increment(); return HTTPByteStream(response:HTTPResponse(),chunks:pair.stream,cancel:{ cancelled.increment(); pair.continuation.finish() }) })
        let lm = try OpenAIChatLM(apiKey:"placeholder",env:[:],transport:transport), request = try Request(model:"unit",messages:[.user("hi")])
        let task = Task { try await lm.responseStream(request).response() }
        for _ in 0..<100 { if await started.value > 0 { break }; try await Task.sleep(for:.milliseconds(2)) }
        task.cancel(); do { _ = try await task.value; XCTFail("cancelled stream returned success") } catch {}
        XCTAssertGreaterThan(cancelled.value,0)
    }
    func testLiveTurnStopsForToolAndLeavesNextBoundary() async throws {
        let socket = try FakeSocket([["type":"response.output_text.delta","delta":"Let me check"],["type":"response.output_item.done","item":["type":"function_call","call_id":"call","name":"lookup","arguments":"{\"city\":\"Oslo\"}"]],["type":"response.done","response":["status":"completed","usage":["input_tokens":3,"output_tokens":2]]]])
        let lm = try OpenAILM(apiKey:"placeholder",env:[:]), session = try await lm.live(LiveConfig(model:"gpt-realtime"),connect:{ request in XCTAssertTrue(request.url.hasPrefix("wss://")); return socket })
        try await session.sendText("Weather?")
        let turn = try await session.turn().result(); XCTAssertEqual(turn.endedBy,"tool_call"); XCTAssertEqual(turn.text,"Let me check"); XCTAssertEqual(turn.toolCalls.first?.name,"lookup")
        let next = try await session.receive(); XCTAssertEqual(next?.rawValue["type"],"turn_end")
        await session.close(); XCTAssertTrue(socket.isClosed); XCTAssertEqual(socket.sentFrames.first?["type"],"session.update")
    }
    func testGeminiSetupMovesAPIKeyAndContextClosesOnError() async throws {
        let socket = try FakeSocket([["setupComplete":[:]]]), lm = try GeminiLM(apiKey:"unit-key",env:[:])
        do {
            try await lm.withLiveSession(LiveConfig(model:"gemini-live"),connect:{ request in
                XCTAssertTrue(request.url.contains("key=unit-key")); XCTAssertTrue(request.headers["x-goog-api-key"].isNull); XCTAssertFalse(request.description.contains("unit-key")); return socket
            }) { _ -> Void in throw ValueError("user callback failed") }
            XCTFail("callback error swallowed")
        } catch is ValueError {}
        XCTAssertTrue(socket.isClosed)
    }
    func testLiveReceiveCancellationClosesSocket() async throws {
        let socket = try FakeSocket([]), lm = try OpenAILM(apiKey:"placeholder",env:[:]), session = try await lm.live(LiveConfig(model:"gpt-realtime"),connect:{ _ in socket })
        let reader = Task { try await session.receive() }; try await Task.sleep(for:.milliseconds(20)); reader.cancel(); _ = try? await reader.value; XCTAssertTrue(socket.isClosed)
    }
}
