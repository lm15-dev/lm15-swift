import Foundation

extension ProviderLM {
    func imageChatRequest(_ request: ImageGenerationRequest) throws -> Request {
        var ext = request.extensions ?? [:]
        if let size = request.size { if ext["generationConfig"]["imageConfig"]["aspectRatio"].isNull { ext["generationConfig"]["imageConfig"]["aspectRatio"] = j(size) } }
        return try Request(model:request.model,messages:[Message(role:.user,parts:[.text(TextPart(text:request.prompt))]+request.images.map(Part.image))],config:Config(extensions:ext))
    }
    func speechChatRequest(_ request: SpeechGenerationRequest) throws -> Request {
        if request.format != nil { try unsupported("speech output format") }; var gen: J = ["responseModalities":["AUDIO"]]
        if let voice = request.voice { gen["speechConfig"] = ["voiceConfig":["prebuiltVoiceConfig":["voiceName":j(voice)]]] }
        return try Request(model:request.model,messages:[Message.user(request.prompt)],config:Config(extensions:J.object(["generationConfig":gen]).merging(request.extensions ?? [:])))
    }
    public func imageGenerateRequest(_ request: ImageGenerationRequest) async throws -> TransportRequest {
        try support("images"); if dialect == "gemini" { return try await buildRequest(imageChatRequest(request)) }
        var payload: J = ["model":j(request.model),"prompt":j(request.prompt)]
        if provider == "xai" {
            if request.size != nil { try unsupported("image size") }; if request.images.count > 1 { try unsupported("multiple input images") }
            if let p = request.images.first { payload["image"] = p.fileId != nil ? ["file_id":j(p.fileId!)] : ["url":p.url != nil ? j(p.url!) : j(try mediaURI(p.rawValue))] }
            return try await emit("POST",request.images.isEmpty ? "images/generations" : "images/edits",payload:payload.merging(request.extensions ?? [:]),headers:endpointHeaders())
        }
        if let size = request.size { payload["size"] = j(size) }; payload = payload.merging(request.extensions ?? [:]).compact()
        if request.images.isEmpty { return try await emit("POST","images/generations",payload:payload,headers:endpointHeaders()) }
        let compat = try compatible(["model":j(request.model)])
        let files = try request.images.enumerated().map { i,p -> MultipartFile in
            if p.url != nil || p.fileId != nil { try unsupported("image edit URL/file_id inputs") }
            return MultipartFile(name:compat["edit_image_field"] == "indexed" ? "image[\(i)]" : "image[]",filename:"image-\(i)",mediaType:p.mediaType,data:try p.bytes())
        }
        let (type,body) = try multipartForm(fields:payload.orderedEntries.map { ($0.key,$0.value.stringValue) },files:files)
        return try await emit("POST","images/edits",headers:endpointHeaders().with("content-type",j(type)),body:body)
    }
    public func imageGenerateFromResponse(_ request: ImageGenerationRequest, response: HTTPResponse) throws -> ImageGenerationResponse {
        try support("images")
        if dialect == "gemini" {
            let r = try parseResponse(imageChatRequest(request),response:response), images = r.message.parts.compactMap { if case .image(let p) = $0 { return p }; return nil }
            if images.isEmpty { throw ProviderError("image generation returned no images") }; let text = r.message.parts.filter { $0.rawValue["type"] == "text" }.map { $0.rawValue["text"].s }.joined()
            return try ImageGenerationResponse(images:images,text:text.isEmpty ? nil : text,id:r.id,model:r.model,usage:r.usage,providerData:r.providerData)
        }
        let d = try response.json(), type = d["output_format"].present ? j("image/"+d["output_format"].s) : J.string("application/octet-stream")
        let images: [ImagePart] = try d["data"].a.compactMap { item in
            if !item.isObject { return nil }; let mime = provider == "xai" ? item["mime_type"].or("application/octet-stream") : type
            if item["b64_json"].isString { return try ImagePart(mediaType:mime.s,data:item["b64_json"].s) }; if item["url"].isString { return try ImagePart(mediaType:mime.s,url:item["url"].s) }; return nil
        }
        if images.isEmpty && provider == "xai" { throw ProviderError("image generation returned no images") }
        let usage: J = provider == "xai" ? [:] : .object(d["usage"].o.filter { ["input_tokens","output_tokens","total_tokens"].contains($0.key) })
        return try ImageGenerationResponse(images:images,usage:Usage(json:usage),providerData:d)
    }
    public func speechGenerateRequest(_ request: SpeechGenerationRequest) async throws -> TransportRequest {
        try support("speech"); if dialect == "gemini" { return try await buildRequest(speechChatRequest(request)) }
        var p = J.object([:]).merging(["model":j(request.model),"input":j(request.prompt)]).merging(request.extensions ?? [:]); if let voice = request.voice { p["voice"] = j(voice) }; if let format = request.format { p["response_format"] = j(format) }
        return try await emit("POST","audio/speech",payload:p,headers:endpointHeaders())
    }
    public func speechGenerateFromResponse(_ request: SpeechGenerationRequest, response: HTTPResponse) throws -> SpeechGenerationResponse {
        try support("speech")
        if dialect == "gemini" {
            let r = try parseResponse(speechChatRequest(request),response:response)
            guard let audio = r.message.parts.compactMap({ if case .audio(let p) = $0 { return p }; return nil }).first else { throw ProviderError("speech generation returned no audio") }
            return try SpeechGenerationResponse(audio:audio,id:r.id,model:r.model,usage:r.usage,providerData:r.providerData)
        }
        let type = try contentMediaType(response); return try SpeechGenerationResponse(audio:AudioPart(mediaType:type,data:response.body.base64EncodedString()),providerData:["content_type":j(type)])
    }
    func contentMediaType(_ response: HTTPResponse) throws -> String { let type = response.headers["content-type"].s.components(separatedBy:";")[0].trimmingCharacters(in:.whitespaces); if type.isEmpty { throw ProviderError("media response has no content-type") }; return type }
    public func generateImage(_ request: ImageGenerationRequest) async throws -> ImageGenerationResponse { try imageGenerateFromResponse(request,response:await sendRequest(imageGenerateRequest(request))) }
    public func generateSpeech(_ request: SpeechGenerationRequest) async throws -> SpeechGenerationResponse { try speechGenerateFromResponse(request,response:await sendRequest(speechGenerateRequest(request))) }
    public func videoSubmitRequest(_ request: VideoGenerationRequest) async throws -> TransportRequest {
        try support("video"); if !request.images.isEmpty { try unsupported("video input images") }; var payload: J; let path: String
        if dialect == "gemini" {
            payload = J.object(["instances":[["prompt":j(request.prompt)]]]).merging(request.extensions ?? [:]); if let seconds = request.seconds, payload["parameters"].isNull { payload["parameters"] = ["durationSeconds":j(seconds)] }
            path = pathID(request.model.hasPrefix("models/") ? request.model : "models/"+request.model,resource:true)+":predictLongRunning"
        } else {
            if provider == "xai" && request.seconds != nil { try unsupported("video duration") }
            payload = J.object([:]).merging(["model":j(request.model),"prompt":j(request.prompt)]).merging(request.extensions ?? [:]); if let seconds = request.seconds { payload["seconds"] = j(String(seconds)) }; path = provider == "xai" ? "videos/generations" : "videos"
        }; return try await emit("POST",path,payload:payload,headers:endpointHeaders())
    }
    func videoJobInfo(_ d: J, videoID: String? = nil) throws -> VideoJobInfo {
        if dialect == "gemini" { guard d["name"].isString && !d["name"].empty else { throw ProviderError("video object carries no id") }; return try VideoJobInfo(id:d["name"].s,status:d["done"] == true ? (d["error"].isObject ? .failed : .completed) : .running,providerData:d) }
        let id = provider == "xai" ? d["request_id"].or(videoID.map(j) ?? .null) : d["id"]
        let status = provider == "xai" ? (d["request_id"].present ? "queued" : ["pending":"running","done":"completed","failed":"failed"][d["status"].s]) : ["queued":"queued","in_progress":"running","completed":"completed","failed":"failed","cancelled":"cancelled"][d["status"].s]
        guard let status else { throw ProviderError("unknown video status") }; guard id.isString && !id.empty else { throw ProviderError("video object carries no id") }
        return try VideoJobInfo(json:["id":id,"status":j(status),"progress":d["progress"].isNumber ? j(d["progress"].i) : .null,"created_at":isoUTC(d["created_at"]),"model":d["model"],"provider_data":d])
    }
    public func videoJobFromBody(_ body: Data, videoID: String? = nil) throws -> VideoJobInfo { try support("video"); return try videoJobInfo(J.parse(body),videoID:videoID) }
    public func videoStatusRequest(_ id: String) async throws -> TransportRequest { try support("video"); return try await emit("GET",dialect == "gemini" ? pathID(id,resource:true) : "videos/"+pathID(id),headers:endpointHeaders()) }
    public func videoResultFetch(_ statusBody: JSONValue) async throws -> TransportRequest? {
        try support("video"); if provider == "xai" { return nil }
        let path = dialect == "gemini" ? statusBody["response"]["generateVideoResponse"]["generatedSamples"][0]["video"]["uri"].s : (statusBody["id"].isString && !statusBody["id"].empty ? "videos/"+pathID(statusBody["id"].s)+"/content" : "")
        if path.isEmpty { throw ProviderError("finished video carries no download location") }; return try await emit("GET",path,headers:endpointHeaders())
    }
    public func videoPart(_ statusBody: JSONValue, fetched: HTTPResponse? = nil) throws -> VideoPart {
        try support("video")
        if provider == "xai" { let url = statusBody["video"]["url"]; guard url.isString && !url.empty else { throw ProviderError("finished video carries no URL") }; return try VideoPart(mediaType:"video/mp4",url:url.s) }
        guard let fetched else { throw ProviderError("video bytes were not fetched") }; return try VideoPart(mediaType:contentMediaType(fetched),data:fetched.body.base64EncodedString())
    }
    public func videoListRequest(limit: Int = 20, model: String? = nil) async throws -> TransportRequest {
        try support("video"); if provider == "xai" { try unsupported("listing video jobs") }; let path: String
        if dialect == "gemini" { guard let model else { try unsupported("video listing without a model") }; path = pathID(model.hasPrefix("models/") ? model : "models/"+model,resource:true)+"/operations" } else { path = "videos" }
        return try await emit("GET",path,params:.object([dialect == "gemini" ? "pageSize" : "limit":j(limit)]),headers:endpointHeaders())
    }
    public func videoJobsFromListBody(_ body: Data) throws -> [VideoJobInfo] { try support("video"); if provider == "xai" { try unsupported("listing video jobs") }; let d = try J.parse(body); return try d[dialect == "gemini" ? "operations" : "data"].a.map { try videoJobInfo($0) } }
    public func submitVideo(_ request: VideoGenerationRequest) async throws -> VideoJobInfo { try videoJobFromBody(await sendRequest(videoSubmitRequest(request)).body) }
    public func videoStatus(_ id: String) async throws -> VideoJobInfo { try videoJobFromBody(await sendRequest(videoStatusRequest(id)).body,videoID:id) }
    public func listVideos(limit: Int = 20, model: String? = nil) async throws -> [VideoJobInfo] { try videoJobsFromListBody(await sendRequest(videoListRequest(limit:limit,model:model)).body) }
    public func videoResult(_ id: String) async throws -> VideoPart { let info = try await videoStatus(id); if info.status != .completed { throw ProviderError("video has not completed successfully") }; let raw = info.providerData ?? [:]; var fetched: HTTPResponse?; if let wire = try await videoResultFetch(raw) { fetched = try await sendRequest(wire) }; return try videoPart(raw,fetched:fetched) }
}
