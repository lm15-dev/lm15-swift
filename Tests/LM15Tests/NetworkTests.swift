import XCTest
import Foundation
import Crypto
@testable import LM15
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Single-request local HTTP fixture; no provider account, Python, or external service.
final class LoopbackHTTP: @unchecked Sendable {
    let listener: Int32, url: String
    init(chunks: [String], pause: TimeInterval = 0.015, contentType: String = "text/event-stream", webSocket: Bool = false, rawFrames: [UInt8]? = nil, invalidAccept: Bool = false) throws {
        #if os(Linux)
        let fd = socket(AF_INET,Int32(SOCK_STREAM.rawValue),0)
        #else
        let fd = socket(AF_INET,SOCK_STREAM,0)
        #endif
        guard fd >= 0 else { throw TransportError("fixture socket failed") }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr = in_addr(s_addr:UInt32(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd,1) == 0 else { close(fd); throw TransportError("fixture bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&addr) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
        listener = fd; url = "http://127.0.0.1:\(UInt16(bigEndian:addr.sin_port))"
        DispatchQueue.global().async {
            let client = accept(fd,nil,nil); guard client >= 0 else { return }; defer { close(client) }
            #if !os(Linux)
            var yes: Int32 = 1; _ = setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))
            #endif
            var buffer = [UInt8](repeating:0,count:4096), received = Data()
            while received.count < 65_536 { let n = recv(client,&buffer,buffer.count,0); if n <= 0 { return }; received.append(contentsOf:buffer.prefix(n)); if let header = received.range(of:Data("\r\n\r\n".utf8)) { let lines = String(decoding:received[..<header.lowerBound],as:UTF8.self).components(separatedBy:"\r\n"); let lengthLine = lines.first { $0.lowercased().hasPrefix("content-length:") }; let bodyLength = lengthLine.flatMap { Int($0.dropFirst(15).trimmingCharacters(in:.whitespaces)) } ?? 0; if received.count >= header.upperBound+bodyLength { break } } }
            func write(_ text: String) -> Bool { let bytes = Array(text.utf8); var offset = 0; while offset < bytes.count {
                let n = bytes.withUnsafeBytes { pointer in
                    #if os(Linux)
                    send(client,pointer.baseAddress!.advanced(by:offset),bytes.count-offset,Int32(MSG_NOSIGNAL))
                    #else
                    send(client,pointer.baseAddress!.advanced(by:offset),bytes.count-offset,0)
                    #endif
                }; if n <= 0 { return false }; offset += n
            }; return true }
            if webSocket {
                let lines = String(decoding:received,as:UTF8.self).components(separatedBy:"\r\n")
                guard let keyLine = lines.first(where:{ $0.lowercased().hasPrefix("sec-websocket-key:") }) else { return }
                let key = String(keyLine.dropFirst(18)).trimmingCharacters(in:.whitespaces)
                let accept = invalidAccept ? "invalid" : Data(Insecure.SHA1.hash(data:Data((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                guard write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n") else { return }
                let n = recv(client,&buffer,buffer.count,0); guard n > 0 else { return }
                // A ping followed by fragmented UTF-8 text. Foundation handles control frames.
                let frames: [UInt8] = rawFrames ?? [0x89,0,0x01,2,72,101,0x80,3,108,108,111]
                _ = frames.withUnsafeBytes { pointer in
                    #if os(Linux)
                    send(client,pointer.baseAddress!,frames.count,Int32(MSG_NOSIGNAL))
                    #else
                    send(client,pointer.baseAddress!,frames.count,0)
                    #endif
                }
                Thread.sleep(forTimeInterval:0.1); return
            }
            guard write("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nConnection: close\r\n\r\n") else { return }
            for chunk in chunks { Thread.sleep(forTimeInterval:pause); if !write(chunk) { return } }
        }
    }
    deinit { _ = shutdown(listener,Int32(SHUT_RDWR)); close(listener) }
}
final class NetworkTests: XCTestCase, @unchecked Sendable {
    func testNativeWebSocketHandshakePingAndFragmentation() async throws {
        let server = try LoopbackHTTP(chunks:[],webSocket:true)
        let socket = try await connectLiveSocket(TransportRequest(method:"GET",url:server.url.replacingOccurrences(of:"http:",with:"ws:")))
        try await socket.send(Data("hello".utf8)); let message = try await socket.receive()
        XCTAssertEqual(message,Data("Hello".utf8)); socket.close(); withExtendedLifetime(server) {}
    }
    func testWebSocketRejectsMalformedFramesAndUpgrade() async throws {
        #if os(Linux)
        // Linux's custom frame bridge is exercised independently of transcript fixtures.
        let malformed: [[UInt8]] = [[0x81,0x81,0,0,0,0,65],[0x80,1,65],[0x81,1,0xff],[0x83,0],[0x09,0],[0x88,1,0]]
        for frames in malformed {
            let server = try LoopbackHTTP(chunks:[],webSocket:true,rawFrames:frames)
            let socket = try await connectLiveSocket(TransportRequest(method:"GET",url:server.url.replacingOccurrences(of:"http:",with:"ws:"),timeout:2))
            do { try await socket.send(Data("hello".utf8)); _ = try await socket.receive(); XCTFail("malformed frame accepted: \(frames)") } catch is TransportError {}
            socket.close(); withExtendedLifetime(server) {}
        }
        let server = try LoopbackHTTP(chunks:[],webSocket:true,invalidAccept:true)
        do { _ = try await connectLiveSocket(TransportRequest(method:"GET",url:server.url.replacingOccurrences(of:"http:",with:"ws:"),timeout:1)); XCTFail("invalid accept header accepted") } catch is TransportError {}
        withExtendedLifetime(server) {}
        #endif
    }
    func testURLSessionCompleteAndIncrementalSSEOverRealSocket() async throws {
        let complete = try LoopbackHTTP(chunks:[#"{"id":"resp","model":"unit","choices":[{"message":{"content":"Hello"},"finish_reason":"stop"}]}"#],contentType:"application/json")
        let client = try OpenAIChatLM(apiKey:"placeholder",baseURL:complete.url,env:[:]), request = try Request(model:"unit",messages:[.user("hi")])
        let response = try await client.complete(request); XCTAssertEqual(response.text,"Hello")
        let stream = try LoopbackHTTP(chunks:["data: {\"id\":\"r\",\"choices\":[{\"delta\":{\"content\":\"He", "llo\"}}]}\n\n", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n", "data: [DONE]\n\n"])
        let streaming = try OpenAIChatLM(apiKey:"placeholder",baseURL:stream.url,env:[:]); let result = try await streaming.responseStream(request).response(); XCTAssertEqual(result.text,"Hello")
        withExtendedLifetime((complete,stream)) {}
    }
    func testNetworkTruncationCannotBecomeSuccessfulCompletion() async throws {
        let server = try LoopbackHTTP(chunks:["data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"])
        let lm = try OpenAIChatLM(apiKey:"placeholder",baseURL:server.url,env:[:]), request = try Request(model:"unit",messages:[.user("hi")])
        do { _ = try await lm.responseStream(request).response(); XCTFail("truncated HTTP stream accepted") } catch let e as StreamAssemblyError { XCTAssertEqual(e.partialResponse?.text,"partial") }
        withExtendedLifetime(server) {}
    }
    func testNetworkEarlyCloseUnblocksReader() async throws {
        let server = try LoopbackHTTP(chunks:Array(repeating:": heartbeat\n\n",count:10),pause:0.03)
        let lm = try OpenAIChatLM(apiKey:"placeholder",baseURL:server.url,env:[:]), request = try Request(model:"unit",messages:[.user("hi")]), stream = lm.responseStream(request)
        let reader = Task { try await stream.response() }; try await Task.sleep(for:.milliseconds(70)); let start = ContinuousClock.now; await stream.close(); _ = try? await reader.value
        XCTAssertLessThan(start.duration(to:.now),.seconds(1)); withExtendedLifetime(server) {}
    }
}
