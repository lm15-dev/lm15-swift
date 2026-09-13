import Foundation

public enum SystemPrompt: Sendable, Equatable, ExpressibleByStringLiteral {
    case text(String), parts([PromptPart])
    public init(stringLiteral value: String) { self = .text(value) }
    public init(json: JSONValue) throws {
        if json.isString { self = .text(json.s) } else { self = .parts(try json.a.map { try PromptPart(json:$0) }) }
    }
    public var json: JSONValue { switch self { case .text(let x): return .string(x); case .parts(let x): return .array(x.map(\.rawValue)) } }
}
extension Message {
    public static func user(_ text: String) throws -> Message { try Message(role:.user,parts:[.text(TextPart(text:text))]) }
    public static func user(_ parts: [PromptPart]) throws -> Message { try Message(role:.user,parts:parts.map { try Part(json:$0.rawValue) }) }
    public static func developer(_ text: String) throws -> Message { try Message(role:.developer,parts:[.text(TextPart(text:text))]) }
    public static func assistant(_ text: String) throws -> Message { try Message(role:.assistant,parts:[.text(TextPart(text:text))]) }
    public static func assistant(_ parts: [Part]) throws -> Message { try Message(role:.assistant,parts:parts) }
    public static func tool(id: String, text: String, isError: Bool = false) throws -> Message { try Message(role:.tool,parts:[.toolResult(ToolResultPart(id:id,content:[.text(TextPart(text:text))],isError:isError))]) }
    public var text: String? { parts.allSatisfy { $0.rawValue["type"] == "text" } ? parts.map { $0.rawValue["text"].s }.joined(separator:"\n") : nil }
}
extension Response {
    public var text: String? { let p = message.parts.filter { $0.rawValue["type"] == "text" }; return p.isEmpty ? nil : p.map { $0.rawValue["text"].s }.joined(separator:"\n") }
    public var toolCalls: [ToolCallPart] { message.parts.compactMap { if case .toolCall(let p) = $0 { return p }; return nil } }
    public var citations: [CitationPart] { message.parts.compactMap { if case .citation(let p) = $0 { return p }; return nil } }
    public func json() throws -> JSONValue { try .parse(text ?? "") }
}
extension Request {
    public func with(model: String? = nil, messages: [Message]? = nil, config: Config? = nil) throws -> Request { try Request(model:model ?? self.model,messages:messages ?? self.messages,system:system,tools:tools,config:config ?? self.config) }
}
extension FileInfo { public var ready: Bool { readiness == .ready } }
extension BatchJobInfo { public var done: Bool { [.completed,.failed,.cancelled,.expired].contains(status) } }
extension VideoJobInfo { public var done: Bool { [.completed,.failed,.cancelled].contains(status) } }
extension ContinuationDelta { public func toState() throws -> ContinuationState { try ContinuationState(provider:provider,kind:kind,data:data) } }
extension Reasoning { public var isOff: Bool { effort == .off } }
extension ToolChoice { public static func fromTools(_ tools: [Tool], mode: ToolChoiceMode = .auto, parallel: Bool? = nil) throws -> ToolChoice { try ToolChoice(mode:mode,allowed:tools.map { $0.rawValue["name"].s },parallel:parallel) } }
extension ApiKey: CustomStringConvertible {}
extension BearerToken: CustomStringConvertible {}
extension AwsCredentials: CustomStringConvertible {}
extension Credential: CustomStringConvertible { public var description: String { "Credential([REDACTED])" } }
