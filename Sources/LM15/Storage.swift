import Foundation

struct MultipartFile { let name: String, filename: String, mediaType: String; let data: Data }
func multipartForm(fields: [(String,String)] = [], files: [MultipartFile] = []) throws -> (String,Data) {
    let boundary = "lm15-"+UUID().uuidString.replacingOccurrences(of:"-",with:""); var body = Data()
    func quoted(_ s: String) -> String { s.replacingOccurrences(of:"\r",with:"%0D").replacingOccurrences(of:"\n",with:"%0A").replacingOccurrences(of:"\"",with:"%22") }
    func append(_ s: String) { body.append(Data(s.utf8)) }
    for (name,value) in fields { append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(name))\"\r\n\r\n\(value)\r\n") }
    for f in files { guard !f.mediaType.contains("\r") && !f.mediaType.contains("\n") else { throw ValueError("invalid multipart media type") }; append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(f.name))\"; filename=\"\(quoted(f.filename))\"\r\nContent-Type: \(f.mediaType)\r\n\r\n"); body.append(f.data); append("\r\n") }
    append("--\(boundary)--\r\n"); return ("multipart/form-data; boundary=\(boundary)",body)
}
func multipartRelated(metadata: J, mediaType: String, data: Data) throws -> (String,Data) {
    guard !mediaType.contains("\r") && !mediaType.contains("\n") else { throw ValueError("invalid multipart media type") }
    let boundary = "lm15-"+UUID().uuidString
    var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(try metadata.jsonString(sortedKeys:false))\r\n--\(boundary)\r\nContent-Type: \(mediaType)\r\n\r\n".utf8); body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8)); return ("multipart/related; boundary=\(boundary)",body)
}
extension FileUploadRequest { public func bytes() throws -> Data { if let bytesData { return bytesData }; return try Data(contentsOf:URL(fileURLWithPath:path!)) } }
public protocol MediaPart: CanonicalValue { var data: String? { get }; var path: String? { get } }
extension MediaPart {
    public func bytes() throws -> Data { if let data, let bytes = Data(base64Encoded:data) { return bytes }; if let path { return try Data(contentsOf:URL(fileURLWithPath:path)) }; throw ValueError("URL and file_id sources have no local bytes") }
}
extension ImagePart: MediaPart {}; extension AudioPart: MediaPart {}; extension VideoPart: MediaPart {}; extension DocumentPart: MediaPart {}; extension BinaryPart: MediaPart {}
func isoUTC(_ value: J) -> J { if value.isNumber { return j(isoDate(Date(timeIntervalSince1970:value.d))) }; if let date = parseDate(value.s) { return j(isoDate(date)) }; return .null }
extension ProviderLM {
    func endpointHeaders() -> J { if dialect == "gemini" { return [:] }; return dialect == "anthropic" ? ["content-type":"application/json","anthropic-version":"2023-06-01"] : ["content-type":"application/json"] }
    public func sendRequest(_ request: TransportRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        if response.status >= 400 { throw normalizeError(status:response.status,body:String(decoding:response.body,as:UTF8.self),headers:response.headers) }; return response
    }
    public func modelsRequest() async throws -> TransportRequest {
        try support("models"); var params: J = dialect == "gemini" ? ["pageSize":1000] : dialect == "anthropic" ? ["limit":1000] : [:]
        if provider == "openai-codex" { params["client_version"] = access.value["backend_options"]["client_version"] }; return try await emit("GET","models",params:params,headers:endpointHeaders())
    }
    public func modelsFromBody(_ body: Data) throws -> [ModelInfo] {
        try support("models"); let d = try J.parse(body), key = provider == "openai-codex" || dialect == "gemini" ? "models" : "data", idKey = provider == "openai-codex" ? "slug" : dialect == "gemini" ? "name" : "id"
        let family = ["openai-chat":"openai_chat","openai-responses":"openai_responses","anthropic":"anthropic_messages","gemini":"gemini_generate_content"][dialect]!
        return try d[key].a.compactMap { entry in guard entry.isObject, entry[idKey].isString, !entry[idKey].empty else { return nil }; var id = entry[idKey].s; if dialect == "gemini" && id.hasPrefix("models/") { id = String(id.dropFirst(7)) }; if id.isEmpty { return nil }; return try ModelInfo(id:id,provider:provider,apiFamily:family,origin:ModelOrigin(type:"provider",providerData:entry)) }
    }
    public func listModels() async throws -> [ModelInfo] { try modelsFromBody(await sendRequest(modelsRequest()).body) }
    func fileResource(_ id: String) -> String { let clean = id.replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression); if id.contains("://") && clean.contains("/files/") { return "files/"+clean.components(separatedBy:"/files/").last! }; return id.hasPrefix("files/") ? id : "files/"+id }
    func filePath(_ id: String) -> String { dialect == "gemini" ? pathID(fileResource(id),resource:true) : "files/"+pathID(id) }
    public func fileUploadRequest(_ request: FileUploadRequest) async throws -> TransportRequest {
        try support("files")
        if dialect == "gemini" { let (type,body) = try multipartRelated(metadata:["file":["display_name":j(request.filename)]],mediaType:request.mediaType,data:request.bytes()); return try await emit("POST","https://generativelanguage.googleapis.com/upload/v1beta/files",params:request.extensions ?? [:],headers:["x-goog-upload-protocol":"multipart","content-type":j(type)],body:body) }
        var ext = request.extensions ?? [:], fields: [(String,String)] = []
        if dialect != "anthropic" { fields.append(("purpose",ext["purpose"].or("user_data").s)); ext = ext.without(["purpose"]) }
        fields += ext.orderedEntries.map { ($0.key,$0.value.stringValue) }
        let (type,body) = try multipartForm(fields:fields,files:[MultipartFile(name:"file",filename:request.filename,mediaType:request.mediaType,data:request.bytes())])
        return try await emit("POST","files",headers:endpointHeaders().with("content-type",j(type)),body:body)
    }
    public func fileGetRequest(_ id: String) async throws -> TransportRequest { try support("files"); return try await emit("GET",filePath(id),headers:endpointHeaders()) }
    public func fileDeleteRequest(_ id: String) async throws -> TransportRequest { try support("files"); return try await emit("DELETE",filePath(id),headers:endpointHeaders()) }
    public func fileDownloadRequest(_ id: String) async throws -> TransportRequest { try support("files"); return try await emit("GET",filePath(id)+(dialect == "gemini" ? ":download?alt=media" : "/content"),headers:endpointHeaders()) }
    public func fileListRequest(limit: Int = 20, cursor: String? = nil) async throws -> TransportRequest {
        try support("files"); let params: J = dialect == "gemini" ? ["pageSize":j(limit),"pageToken":cursor.map(j) ?? .null] : .object(["limit":j(limit),dialect == "anthropic" ? "page" : "after":cursor.map(j) ?? .null]); return try await emit("GET","files",params:params,headers:endpointHeaders())
    }
    func fileInfo(_ d: J) throws -> FileInfo {
        let id: J, name: J, mime: J, size: J, created: J, expires: J, download: J, ready: String
        switch dialect {
        case "gemini":
            id = nonempty(d["uri"]).or(nonempty(d["name"])); name = d["displayName"]; mime = d["mimeType"]; created = d["createTime"]; expires = d["expirationTime"]
            size = Int(d["sizeBytes"].stringValue).map(j) ?? .null; let state = d["state"].s; ready = state.hasSuffix("PROCESSING") ? "pending" : state.hasSuffix("FAILED") ? "failed" : "ready"; download = nonempty(d["downloadUri"]).present ? true : d["source"] == "UPLOADED" ? false : .null
        case "anthropic": id = d["id"]; name = d["filename"]; mime = d["mime_type"]; size = d["size_bytes"]; created = d["created_at"]; expires = d["expires_at"]; download = d["downloadable"] == true || d["downloadable"] == false ? d["downloadable"] : .null; ready = "ready"
        default: id = d["id"]; name = d["filename"]; mime = .null; size = d["bytes"]; created = d["created_at"]; expires = d["expires_at"]; download = .null; ready = ["uploaded":"pending","pending":"pending","error":"failed","failed":"failed","processed":"ready"][d["status"].s] ?? "ready"
        }
        guard id.isString && !id.empty else { throw ProviderError("file object carries no id") }
        return try FileInfo(json:["id":id,"filename":name.isString ? nonempty(name) : .null,"media_type":mime.isString ? nonempty(mime) : .null,"size_bytes":wireType(size) == "int" ? size : .null,"created_at":isoUTC(created),"expires_at":isoUTC(expires),"readiness":j(ready),"downloadable":download,"provider_data":d])
    }
    public func fileInfoFromBody(_ body: Data) throws -> FileInfo { try support("files"); let d = try J.parse(body); return try fileInfo(dialect == "gemini" && d["file"].isObject ? d["file"] : d) }
    public func filePageFromListBody(_ body: Data) throws -> FilePage {
        try support("files"); let d = try J.parse(body), items = try d[dialect == "gemini" ? "files" : "data"].a.filter(\.isObject).map(fileInfo)
        let cursor = dialect == "gemini" ? d["nextPageToken"] : dialect == "anthropic" ? d["next_page"] : d["has_more"].b && !items.isEmpty ? d["last_id"] : .null
        return try FilePage(items:items,nextCursor:cursor.isString && !cursor.empty ? cursor.s : nil)
    }
    public func fileUpload(_ request: FileUploadRequest) async throws -> FileInfo { try fileInfoFromBody(await sendRequest(fileUploadRequest(request)).body) }
    public func fileGet(_ id: String) async throws -> FileInfo { try fileInfoFromBody(await sendRequest(fileGetRequest(id)).body) }
    public func fileList(limit: Int = 20, cursor: String? = nil) async throws -> FilePage { try filePageFromListBody(await sendRequest(fileListRequest(limit:limit,cursor:cursor)).body) }
    public func fileDelete(_ id: String) async throws { _ = try await sendRequest(fileDeleteRequest(id)) }
    public func fileDownload(_ id: String) async throws -> Data { try await sendRequest(fileDownloadRequest(id)).body }
    static func checkCachePrefix(_ prefix: Request, _ ttl: Int?) throws { if !prefix.config.toJSON().empty { throw ValueError("cached prefix must carry a default Config") }; if let ttl, ttl <= 0 { throw ValueError("ttlSeconds must be positive") } }
    func cachePath(_ id: String) -> String { pathID(id.hasPrefix("cachedContents/") ? id : "cachedContents/"+id,resource:true) }
    public func cacheCreateRequest(_ prefix: Request, ttlSeconds: Int? = nil, label: String? = nil) async throws -> TransportRequest {
        try support("caches"); try Self.checkCachePrefix(prefix,ttlSeconds); var p = try geminiPayload(prefix.rawValue).with("model",j(prefix.model.hasPrefix("models/") ? prefix.model : "models/"+prefix.model))
        if let ttlSeconds { p["ttl"] = j("\(ttlSeconds)s") }; if let label { p["displayName"] = j(label) }; return try await emit("POST","cachedContents",payload:p)
    }
    public func cacheGetRequest(_ id: String) async throws -> TransportRequest { try support("caches"); return try await emit("GET",cachePath(id)) }
    public func cacheDeleteRequest(_ id: String) async throws -> TransportRequest { try support("caches"); return try await emit("DELETE",cachePath(id)) }
    public func cacheUpdateRequest(_ id: String, ttlSeconds: Int) async throws -> TransportRequest { try support("caches"); if ttlSeconds <= 0 { throw ValueError("ttlSeconds must be positive") }; return try await emit("PATCH",cachePath(id),payload:["ttl":j("\(ttlSeconds)s")]) }
    public func cacheListRequest(limit: Int = 20, cursor: String? = nil) async throws -> TransportRequest { try support("caches"); return try await emit("GET","cachedContents",params:["pageSize":j(limit),"pageToken":cursor.map(j) ?? .null]) }
    func cacheInfo(_ d: J) throws -> CacheInfo {
        let id = d["name"], model = d["model"], count = d["usageMetadata"]["totalTokenCount"]
        guard id.isString && !id.empty && model.isString && !model.empty else { throw ProviderError("cache object carries no name or model") }
        return try CacheInfo(json:["id":id,"model":j(model.s.hasPrefix("models/") ? String(model.s.dropFirst(7)) : model.s),"tokens":Int(count.stringValue).flatMap { $0 >= 0 ? j($0) : nil } ?? .null,"created_at":isoUTC(d["createTime"]),"expires_at":isoUTC(d["expireTime"]),"label":nonempty(d["displayName"]),"provider_data":d])
    }
    public func cacheInfoFromBody(_ body: Data) throws -> CacheInfo { try support("caches"); return try cacheInfo(J.parse(body)) }
    public func cachePageFromListBody(_ body: Data) throws -> CachePage { try support("caches"); let d = try J.parse(body); return try CachePage(items:d["cachedContents"].a.filter(\.isObject).map(cacheInfo),nextCursor:nonempty(d["nextPageToken"]).isNull ? nil : d["nextPageToken"].s) }
    public func cacheCreate(_ prefix: Request, ttlSeconds: Int? = nil, label: String? = nil) async throws -> CacheInfo { try cacheInfoFromBody(await sendRequest(cacheCreateRequest(prefix,ttlSeconds:ttlSeconds,label:label)).body) }
    public func cacheGet(_ id: String) async throws -> CacheInfo { try cacheInfoFromBody(await sendRequest(cacheGetRequest(id)).body) }
    public func cacheUpdate(_ id: String, ttlSeconds: Int) async throws -> CacheInfo { try cacheInfoFromBody(await sendRequest(cacheUpdateRequest(id,ttlSeconds:ttlSeconds)).body) }
    public func cacheList(limit: Int = 20, cursor: String? = nil) async throws -> CachePage { try cachePageFromListBody(await sendRequest(cacheListRequest(limit:limit,cursor:cursor)).body) }
    public func cacheDelete(_ id: String) async throws { _ = try await sendRequest(cacheDeleteRequest(id)) }
    public func cache(_ prefix: Request, ttlSeconds: Int? = nil, label: String? = nil) async throws -> CachedPrefix { try Self.checkCachePrefix(prefix,ttlSeconds); return try await CachedPrefix(prefix:prefix,resource:access.supports("caches") ? cacheCreate(prefix,ttlSeconds:ttlSeconds,label:label) : nil) }
}
