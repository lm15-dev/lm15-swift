import Foundation

extension ProviderLM {
    public func batchUploadRequest(_ request: BatchRequest) async throws -> TransportRequest? {
        try support("batches"); if dialect != "openai-responses" { return nil }
        let lines = try request.requests.enumerated().map { i,r in try J.object([:]).merging(["custom_id":j(String(i)),"method":"POST","url":"/v1/responses","body":responsesPayload(r.rawValue,false)]).jsonString(sortedKeys:false) }.joined(separator:"\n")+"\n"
        let (type,body) = try multipartForm(fields:[("purpose","batch")],files:[MultipartFile(name:"file",filename:"lm15-batch.jsonl",mediaType:"application/jsonl",data:Data(lines.utf8))]); return try await emit("POST","files",headers:endpointHeaders().with("content-type",j(type)),body:body)
    }
    public func batchSubmitRequest(_ request: BatchRequest, uploadBody: JSONValue = .null) async throws -> TransportRequest {
        try support("batches"); var ext = request.extensions ?? [:], payload: J; let path: String
        switch dialect {
        case "openai-responses":
            guard uploadBody["id"].isString && !uploadBody["id"].empty else { throw ProviderError("batch upload returned no id") }
            payload = ["input_file_id":uploadBody["id"],"endpoint":ext["endpoint"].or("/v1/responses"),"completion_window":ext["completion_window"].or("24h")]; ext = ext.without(["endpoint","completion_window"])
            if let label = request.label { payload["metadata"] = ["label":j(label)] }; path = "batches"
        case "anthropic":
            if request.label != nil { try unsupported("batch labels") }
            payload = ["requests":arr(try request.requests.enumerated().map { i,r in ["custom_id":j(String(i)),"params":try anthropicPayload(r.rawValue,false)] })]; path = "messages/batches"
        case "gemini":
            var batch: J = ["inputConfig":["requests":["requests":arr(try request.requests.enumerated().map { i,r in ["request":try geminiPayload(r.rawValue),"metadata":["key":j(String(i))]] })]]]
            if let label = request.label { batch["displayName"] = j(label) }; payload = ["batch":batch]
            let model = request.model ?? request.requests[0].model; path = pathID(model.hasPrefix("models/") ? model : "models/"+model,resource:true).replacingOccurrences(of:"%3A",with:":").replacingOccurrences(of:"%40",with:"@")+":batchGenerateContent"
        default: try unsupported("batches")
        }
        return try await emit("POST",path,payload:payload.merging(ext),headers:endpointHeaders())
    }
    func batchJobInfo(_ d: J) throws -> BatchJobInfo {
        let id: J, created: J, label: J; var status = "queued"
        switch dialect {
        case "anthropic":
            id = d["id"]; created = d["created_at"]; label = .null
            if d["processing_status"] == "in_progress" { status = "running" } else if d["processing_status"] == "canceling" { status = "cancelling" }
            else if d["processing_status"] == "ended" { let c = d["request_counts"]
                if c["canceled"].i > 0 && ["succeeded","errored","expired"].allSatisfy({ c[$0].i == 0 }) { status = "cancelled" }
                else if c["expired"].i > 0 && ["succeeded","errored","canceled"].allSatisfy({ c[$0].i == 0 }) { status = "expired" }
                else { status = "completed" }
            }
        case "gemini":
            let meta = d["metadata"]; id = d["name"]; label = meta["displayName"]; created = meta["createTime"]
            status = ["PENDING":"queued","RUNNING":"running","CANCELLING":"cancelling","SUCCEEDED":"completed","FAILED":"failed","CANCELLED":"cancelled","EXPIRED":"expired"][meta["state"].s.replacingOccurrences(of:"BATCH_STATE_",with:"")] ?? (d["done"].b ? "completed" : "queued")
        default:
            id = d["id"]; created = d["created_at"]; label = d["metadata"]["label"]
            let s = d["status"].s.lowercased(); if ["completed","failed","cancelled","expired"].contains(s) { status = s } else if ["cancelling","canceling"].contains(s) { status = "cancelling" } else if ["in_progress","finalizing"].contains(s) { status = "running" }
        }
        guard id.isString && !id.empty else { throw ProviderError("batch object carries no id") }
        return try BatchJobInfo(json:["id":id,"status":j(status),"label":label.isString ? nonempty(label) : .null,"created_at":isoUTC(created),"provider_data":d])
    }
    public func batchJobFromBody(_ body: Data) throws -> BatchJobInfo { try support("batches"); return try batchJobInfo(J.parse(body)) }
    func batchPath(_ id: String) -> String { dialect == "gemini" ? pathID(id,resource:true) : (dialect == "anthropic" ? "messages/batches/" : "batches/")+pathID(id) }
    public func batchStatusRequest(_ id: String) async throws -> TransportRequest { try support("batches"); return try await emit("GET",batchPath(id),headers:endpointHeaders()) }
    public func batchCancelRequest(_ id: String) async throws -> TransportRequest { try support("batches"); return try await emit("POST",batchPath(id)+(dialect == "gemini" ? ":cancel" : "/cancel"),payload:dialect == "gemini" ? [:] : .null,headers:endpointHeaders()) }
    public func batchListRequest(limit: Int = 20) async throws -> TransportRequest { try support("batches"); return try await emit("GET",dialect == "anthropic" ? "messages/batches" : "batches",params:.object([dialect == "gemini" ? "pageSize" : "limit":j(limit)]),headers:endpointHeaders()) }
    public func batchJobsFromListBody(_ body: Data) throws -> [BatchJobInfo] { try support("batches"); let d = try J.parse(body); return try d[dialect == "gemini" ? "operations" : "data"].a.filter(\.isObject).map(batchJobInfo) }
    public func batchResultFetches(_ statusBody: JSONValue) async throws -> [TransportRequest] {
        try support("batches"); if dialect == "gemini" { return [] }
        if dialect == "anthropic" { let url = statusBody["results_url"]; guard url.isString && !url.empty else { throw ProviderError("ended batch carries no results_url") }; return [try await emit("GET",url.s,headers:endpointHeaders())] }
        var out: [TransportRequest] = []; for key in ["output_file_id","error_file_id"] { let id = statusBody[key]; if id.isString && !id.empty { out.append(try await emit("GET","files/"+pathID(id.s)+"/content",headers:endpointHeaders())) } }; return out
    }
    func batchEntryResponse(_ body: J, model: String? = nil) throws -> Response { let request = try Request(model:model ?? (body["model"].isNull ? "unknown" : body["model"].s),messages:[Message.user("")]); return try parseResponse(request,response:HTTPResponse(json:body)) }
    func batchError(_ index: Int, _ status: Int, _ body: J) throws -> BatchEntry { let e = normalizeError(status:status,body:try body.jsonString()); return try BatchEntry(index:index,outcome:.errored,error:ErrorDetail(json:["code":j(e.code),"message":j(e.message.isEmpty ? "batch entry errored" : e.message),"provider_code":e.metadata["provider_code"]])) }
    public func batchEntries(_ statusBody: JSONValue, fetched: [Data] = []) throws -> [BatchEntry] {
        try support("batches")
        if dialect == "gemini" {
            var inlined = statusBody["response"]["inlinedResponses"]; if inlined.isObject { inlined = inlined["inlinedResponses"] }
            return try inlined.a.enumerated().compactMap { position,item -> BatchEntry? in
                guard item.isObject else { return nil }; let index = Int(item["metadata"]["key"].stringValue) ?? position
                if item["response"].isObject { let body = item["response"]; return try BatchEntry(index:index,outcome:.succeeded,response:batchEntryResponse(body,model:body["modelVersion"].isNull ? nil : body["modelVersion"].s)) }
                let e = item["error"], pc = e["status"].or(e["code"]); return try BatchEntry(index:index,outcome:.errored,error:ErrorDetail(code:.provider,message:e["message"].or("batch entry errored").stringValue,providerCode:pc.isNull ? nil : pc.stringValue))
            }.sorted { $0.index < $1.index }
        }
        var found: [Int:BatchEntry] = [:]
        for data in fetched { for line in String(decoding:data,as:UTF8.self).split(separator:"\n") where !line.trimmingCharacters(in:.whitespaces).isEmpty {
            let item = try J.parse(String(line)); guard let index = Int(item["custom_id"].stringValue) else { throw ValueError("batch custom_id must be an integer") }; let entry: BatchEntry
            if dialect == "anthropic" {
                let result = item["result"]
                switch result["type"].s {
                case "succeeded": entry = try BatchEntry(index:index,outcome:.succeeded,response:batchEntryResponse(result["message"].or([:])))
                case "errored": let raw = result["error"].or([:]); entry = try batchError(index,400,raw.isObject && raw.has("error") ? raw : ["error":raw])
                case "canceled": entry = try BatchEntry(index:index,outcome:.cancelled)
                case "expired": entry = try BatchEntry(index:index,outcome:.expired)
                default: entry = try BatchEntry(index:index,outcome:.errored,error:ErrorDetail(code:.provider,message:"unrecognized batch result type \(result["type"].s)"))
                }
            } else {
                let response = item["response"], status = response["status_code"].i, body = response["body"].or([:])
                entry = status == 200 && !body.empty ? try BatchEntry(index:index,outcome:.succeeded,response:batchEntryResponse(body)) : try batchError(index,status == 0 ? 400 : status,body.empty ? item["error"].or([:]) : body)
            }; found[index] = entry
        } }
        if dialect == "anthropic" { return found.values.sorted { $0.index < $1.index } }
        let count = statusBody["request_counts"]["total"].i, total = count == 0 ? (found.keys.max() ?? -1)+1 : count, status = try batchJobInfo(statusBody).status
        return try (0..<max(0,total)).map { i in if let entry = found[i] { return entry }; if status == .expired || status == .cancelled { return try BatchEntry(index:i,outcome:status == .expired ? .expired : .cancelled) }; return try BatchEntry(index:i,outcome:.errored,error:ErrorDetail(code:.provider,message:"entry missing from batch output files")) }
    }
    public func batchSubmit(_ request: BatchRequest) async throws -> BatchJobInfo {
        var uploaded: J = .null; if let upload = try await batchUploadRequest(request) { uploaded = try await sendRequest(upload).json() }
        return try batchJobFromBody(await sendRequest(batchSubmitRequest(request,uploadBody:uploaded)).body)
    }
    public func batchStatus(_ id: String) async throws -> BatchJobInfo { try batchJobFromBody(await sendRequest(batchStatusRequest(id)).body) }
    public func batchCancel(_ id: String) async throws -> BatchJobInfo { try batchJobFromBody(await sendRequest(batchCancelRequest(id)).body) }
    public func batchList(limit: Int = 20) async throws -> [BatchJobInfo] { try batchJobsFromListBody(await sendRequest(batchListRequest(limit:limit)).body) }
    public func batchResults(_ id: String) async throws -> [BatchEntry] {
        let res = try await sendRequest(batchStatusRequest(id)), info = try batchJobFromBody(res.body)
        if !info.done { throw ValueError("batch is not finished") }; let status = try res.json(); var fetched: [Data] = []
        for wire in try await batchResultFetches(status) { fetched.append(try await sendRequest(wire).body) }; return try batchEntries(status,fetched:fetched)
    }
}
