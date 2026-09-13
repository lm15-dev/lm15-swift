import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TransportRequest: Sendable, CustomStringConvertible {
    public let method: String, url: String
    public let headers: JSONValue, body: Data
    public let timeout: TimeInterval
    public init(method: String, url: String, headers: JSONValue = [:], body: Data = Data(), params: JSONValue = [:], timeout: TimeInterval = 120) throws {
        guard URL(string:url)?.host != nil else { throw ValueError("invalid request URL") }
        self.method = method.uppercased(); self.headers = .object(headers.o.reduce(into:[:]) { $0[$1.key.lowercased()] = $1.value }); self.body = body; self.timeout = timeout
        let query = params.o.filter { $0.value.present }.sorted { $0.key < $1.key }.map { pathID($0.key)+"="+pathID($0.value.stringValue) }.joined(separator:"&")
        self.url = url + (query.isEmpty ? "" : (url.contains("?") ? "&" : "?") + query)
    }
    public func normalized() throws -> JSONValue {
        let parts = url.components(separatedBy:"?"); var params: J = [:]
        if parts.count > 1 { for pair in parts[1].components(separatedBy:"&") where !pair.isEmpty { let kv = pair.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false); params[queryDecode(String(kv[0]))] = j(queryDecode(kv.count > 1 ? String(kv[1]) : "")) } }
        var out: J = ["method":j(method),"url":j(parts[0]),"params":params,"headers":headers,"body":nil]
        if !body.isEmpty { if headers["content-type"].s.contains("json") { out["body"] = try J.parse(body) } else { out["body_b64"] = j(body.base64EncodedString()) } }; return out
    }
    public var description: String { "TransportRequest(\(method) \(url.components(separatedBy:"?")[0]))" }
    func urlRequest() throws -> URLRequest {
        guard let target = URL(string:url) else { throw ValueError("invalid URL") }; var r = URLRequest(url:target,timeoutInterval:timeout); r.httpMethod = method
        for (key,value) in headers.o { r.setValue(value.s,forHTTPHeaderField:key) }; if !body.isEmpty { r.httpBody = body }; return r
    }
}
func queryDecode(_ s: String) -> String { s.replacingOccurrences(of:"+",with:" ").removingPercentEncoding ?? s }
public struct HTTPResponse: Sendable {
    public let status: Int, headers: JSONValue, body: Data
    public init(status: Int = 200, headers: JSONValue = [:], body: Data = Data()) { self.status = status; self.headers = .object(headers.o.reduce(into:[:]) { $0[$1.key.lowercased()] = $1.value }); self.body = body }
    public init(status: Int = 200, headers: JSONValue = [:], json: JSONValue) throws { self.init(status:status,headers:headers,body:try json.jsonData()) }
    public func json() throws -> JSONValue { try .parse(body) }
}
public struct HTTPByteStream: Sendable {
    public let response: HTTPResponse
    public let chunks: AsyncThrowingStream<Data, any Error>
    private let cancellation: @Sendable () -> Void
    public init(response: HTTPResponse, chunks: AsyncThrowingStream<Data, any Error>, cancel: @escaping @Sendable () -> Void = {}) { self.response = response; self.chunks = chunks; cancellation = cancel }
    public func cancel() { cancellation() }
}
public protocol HTTPTransport: Sendable {
    func send(_ request: TransportRequest) async throws -> HTTPResponse
    func stream(_ request: TransportRequest) async throws -> HTTPByteStream
}
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: TransportRequest) async throws -> HTTPResponse {
        do { let (data,response) = try await session.data(for:request.urlRequest()); guard let h = response as? HTTPURLResponse else { throw TransportError("non-HTTP response") }; return HTTPResponse(status:h.statusCode,headers:httpHeaders(h),body:data) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError { if e.code == .cancelled { throw CancellationError() }; throw e.code == .timedOut ? TimeoutError(e.localizedDescription) : TransportError(e.localizedDescription) }
    }
    public func stream(_ request: TransportRequest) async throws -> HTTPByteStream {
        let delegate = ByteDelegate()
        return try await withTaskCancellationHandler(operation: { try await delegate.start(request,configuration:session.configuration) },onCancel: { delegate.cancel() })
    }
}
func httpHeaders(_ response: HTTPURLResponse) -> J { .object(response.allHeaderFields.reduce(into:[:]) { out,pair in out[String(describing:pair.key).lowercased()] = j(String(describing:pair.value)) }) }
/// URLSession serializes delegate callbacks; the lock protects cross-task cancellation.
private final class ByteDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let lock = NSLock()
    var task: URLSessionDataTask?, session: URLSession?, header: CheckedContinuation<HTTPByteStream, any Error>?, cancelled = false, finished = false
    let chunks: AsyncThrowingStream<Data, any Error>, continuation: AsyncThrowingStream<Data, any Error>.Continuation
    override init() { let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy:.bufferingOldest(64)); chunks = pair.stream; continuation = pair.continuation; super.init(); continuation.onTermination = { [weak self] _ in self?.cancel() } }
    func start(_ request: TransportRequest, configuration: URLSessionConfiguration) async throws -> HTTPByteStream {
        let req = try request.urlRequest()
        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); defer { lock.unlock() }
            if cancelled { cont.resume(throwing:CancellationError()); return }
            header = cont
            let session = URLSession(configuration:configuration,delegate:self,delegateQueue:nil); self.session = session; task = session.dataTask(with:req); task?.resume()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let t = task, s = session, c = header; header = nil; lock.unlock()
        t?.cancel(); s?.invalidateAndCancel(); c?.resume(throwing:CancellationError())
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let h = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        lock.lock(); let c = header; header = nil; lock.unlock()
        c?.resume(returning:HTTPByteStream(response:HTTPResponse(status:h.statusCode,headers:httpHeaders(h)),chunks:chunks,cancel:{ [self] in cancel() })); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Bound retained payload even when consumers stop polling. Never silently drop bytes.
        for start in stride(from:0,to:data.count,by:16384) {
            let chunk = data.subdata(in:start..<min(start+16384,data.count))
            if case .dropped = continuation.yield(chunk) { continuation.finish(throwing:TransportError("stream consumer exceeded the 1 MiB receive buffer")); cancel(); return }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock(); let c = header; header = nil; finished = true; self.task = nil; self.session = nil; lock.unlock()
        let e: (any Error)? = error.map { error in if let u = error as? URLError { return u.code == .cancelled ? CancellationError() : u.code == .timedOut ? TimeoutError(u.localizedDescription) : TransportError(u.localizedDescription) }; return error }
        c?.resume(throwing:e ?? TransportError("stream ended before headers")); if let e { continuation.finish(throwing:e) } else { continuation.finish() }; session.finishTasksAndInvalidate()
    }
}
