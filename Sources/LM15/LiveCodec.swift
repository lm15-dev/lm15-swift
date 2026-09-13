import Foundation

extension ProviderLM {
    func audioNative(_ model: String) -> Bool { ["native-audio","live-preview"].contains(where:model.lowercased().contains) }
    func liveAudioFormat(_ fmt: AudioFormat) -> J { fmt.encoding == .pcm16 ? ["type":"audio/pcm","rate":j(fmt.sampleRate)] : ["type":j("audio/"+fmt.encoding.rawValue)] }
    public func liveSetupFrames(_ config: LiveConfig) throws -> [JSONValue] {
        try support("live"); let text = config.system == nil ? nil : try systemText(config.rawValue)
        let funcs: [J] = config.tools.filter { $0.rawValue["type"] == "function" }.map { let t = $0.rawValue; return ["name":t["name"],"description":t["description"],"parameters":t["parameters"]] }
        if dialect == "gemini" {
            var setup: J = ["model":j(config.model.hasPrefix("models/") ? config.model : "models/"+config.model)]
            if let text, !text.isEmpty { setup["systemInstruction"] = ["parts":[["text":j(text)]]] }; if !funcs.isEmpty { setup["tools"] = [["functionDeclarations":arr(funcs)]] }
            var gen: J = [:]; if config.outputFormat != nil || audioNative(config.model) { gen["responseModalities"] = ["AUDIO"] }
            if let voice = config.voice { gen["speechConfig"] = ["voiceConfig":["prebuiltVoiceConfig":["voiceName":j(voice)]]] }; if !gen.empty { setup["generationConfig"] = gen }
            setup = setup.merging(config.extensions ?? [:]); if audioNative(config.model) { setup["outputAudioTranscription"] = [:] }; return [["setup":setup]]
        }
        var session: J = ["type":"realtime","output_modalities":config.outputFormat != nil || config.voice != nil ? ["audio"] : ["text"]]
        if let text, !text.isEmpty { session["instructions"] = j(text) }; var audio: J = [:]
        if config.outputFormat != nil || config.voice != nil { var output: J = [:]; if let format = config.outputFormat { output["format"] = liveAudioFormat(format) }; if let voice = config.voice { output["voice"] = j(voice) }; audio["output"] = output }
        if let format = config.inputFormat { audio["input"] = ["format":liveAudioFormat(format),"turn_detection":nil] }; if !audio.empty { session["audio"] = audio }
        if !config.tools.isEmpty { session["tools"] = arr(funcs.map { J.object(["type":"function"]).merging($0) }) }
        return [["type":"session.update","session":session.merging(config.extensions ?? [:])]]
    }
    public func encodeLiveEvent(_ event: LiveClientEvent, config: LiveConfig? = nil) throws -> [JSONValue] {
        try support("live"); let e = event.rawValue
        if dialect == "gemini" {
            switch e["type"].s {
            case "audio","image": return [["realtimeInput":.object([e["type"] == "audio" ? "audio" : "video":["mimeType":e["media_type"],"data":e["data"]]])]]
            case "end_audio": return [["realtimeInput":["audioStreamEnd":true]]]
            case "interrupt": return [["clientContent":["turnComplete":true]]]
            case "text":
                if let config, audioNative(config.model) { return [["realtimeInput":["text":e["text"]]]] }
                return [["clientContent":["turns":[["role":"user","parts":[["text":e["text"]]]]],"turnComplete":true]]]
            case "turn": return [["clientContent":["turns":[["role":"user","parts":arr(try e["parts"].a.map { try geminiPart($0) })]],"turnComplete":e["turn_complete"]]]]
            case "tool_result": return [["toolResponse":["functionResponses":[["id":e["id"],"response":["output":[["text":j(try partsText(e["content"].a))]]]]]]]]
            default: return []
            }
        }
        switch e["type"].s {
        case "audio": return [["type":"input_audio_buffer.append","audio":e["data"]]]
        case "end_audio": return [["type":"input_audio_buffer.commit"],["type":"response.create"]]
        case "interrupt": return [["type":"response.cancel"]]
        default:
            let item: J
            if e["type"] == "tool_result" { item = ["type":"function_call_output","call_id":e["id"],"output":j(try partsText(e["content"].a))] }
            else {
                let parts: [J]
                switch e["type"].s {
                case "text":parts = [["type":"input_text","text":e["text"]]]
                case "image":parts = [["type":"input_image","image_url":j("data:\(e["media_type"].s);base64,\(e["data"].s)")]]
                case "turn":parts = try e["parts"].a.map(openaiInput)
                default:return []
                }
                item = ["type":"message","role":"user","content":arr(parts)]
            }
            var frames: [J] = [["type":"conversation.item.create","item":item]]
            if e["type"] != "turn" || e["turn_complete"].b { frames.append(["type":"response.create"]) }; return frames
        }
    }
    func liveOpenAIUsage(_ response: J) throws -> J {
        var u = response["usage"]; if !u.isObject { return .null }; u["input_tokens_details"] = u["input_token_details"].or(u["input_tokens_details"]); u["output_tokens_details"] = u["output_token_details"].or(u["output_tokens_details"]); return try openaiUsage(u)
    }
    public func decodeLiveEvent(_ raw: Data) throws -> [LiveServerEvent] {
        try support("live"); guard let d = try? J.parse(raw), d.isObject else { return [] }; var events: [J] = []
        if dialect == "gemini" {
            if d.has("error") { let e = d["error"]; return [try LiveServerEvent(json:["type":"error","error":errorDetail(e["status"].or(e["code"]).or("provider"),e["message"].or("").stringValue)])] }
            for fc in d["toolCall"]["functionCalls"].a where fc.isObject { events.append(liveToolCall(fc)) }
            let server = d["serverContent"]
            if server.isObject {
                for p in server["modelTurn"]["parts"].a where p.isObject {
                    if p.has("text") { events.append(["type":"text","text":j(p["text"].or("").stringValue)]) }
                    else if p["inlineData"].isObject { let inline = p["inlineData"]; if inline["mimeType"].s.hasPrefix("audio/") { events.append(["type":"audio","data":j(inline["data"].or("").stringValue),"media_type":inline["mimeType"]]) } }
                    else if p["functionCall"].isObject { events.append(liveToolCall(p["functionCall"])) }
                }
                let tx = server["outputTranscription"]["text"]; if tx.present && !tx.empty { events.append(["type":"text","text":j(tx.stringValue)]) }
                var u = d["usageMetadata"].isObject ? d["usageMetadata"] : server["usageMetadata"]; if u.isObject && u.has("responseTokenCount") { u["candidatesTokenCount"] = u["responseTokenCount"] }
                if u.isObject && !server["turnComplete"].b { events.append(["type":"usage","usage":try geminiUsage(u)]) }
                if server["interrupted"].b { events.append(["type":"interrupted"]) }; if server["turnComplete"].b { events.append(["type":"turn_end","usage":try geminiUsage(u)]) }
            }
        } else {
            switch d["type"].s {
            case "response.output_text.delta","response.text.delta","response.output_audio_transcript.delta","response.audio_transcript.delta": let delta = nonempty(d["delta"]).or(d["text"]); if delta.present && !delta.empty { events.append(["type":"text","text":j(delta.stringValue)]) }
            case "response.output_audio.delta": if nonempty(d["delta"]).present { events.append(["type":"audio","data":j(d["delta"].stringValue)]) }
            case "response.function_call_arguments.delta": if nonempty(d["delta"]).present { events.append(["type":"tool_call_delta","input_delta":j(d["delta"].stringValue),"id":nonempty(d["call_id"]).or(nonempty(d["id"])),"name":nonempty(d["name"])]) }
            case "response.output_item.done": let item = d["item"], id = nonempty(item["call_id"]).or(nonempty(item["id"])); if item["type"] == "function_call" && id.present { events.append(["type":"tool_call","id":id,"name":nonempty(item["name"]).or("tool"),"input":parseObject(item["arguments"])]) }
            case "response.done","response.completed":
                let response = d["response"], u = try liveOpenAIUsage(response)
                if response["status"] == "cancelled" { if u.present { events.append(["type":"usage","usage":u]) }; events.append(["type":"interrupted"]) }
                else if response["output"].a.contains(where: { $0["type"] == "function_call" }) { if u.present { events.append(["type":"usage","usage":u]) } }
                else { events.append(["type":"turn_end","usage":u.or([:])]) }
            case "response.cancelled","response.canceled": events.append(["type":"interrupted"])
            case "error","response.error": let e = d["error"], pc = e["code"].or(e["type"]).or(d["code"]).or(d["error_type"]).or("provider"); if pc != "response_cancel_not_active" { events.append(["type":"error","error":errorDetail(pc,e["message"].or(d["message"]).or("").stringValue)]) }
            default: break
            }
        }; return try events.map { try LiveServerEvent(json:$0) }
    }
    func liveToolCall(_ fc: J) -> J { ["type":"tool_call","id":j(nonempty(fc["id"]).or("fc_0").stringValue),"name":j(nonempty(fc["name"]).or("tool").stringValue),"input":fc["args"].isObject ? fc["args"] : [:]] }
}
