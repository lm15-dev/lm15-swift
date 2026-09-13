import Foundation

public struct ValueError: Error, Sendable, CustomStringConvertible { public let description: String; public init(_ message: String) { description = message } }
public struct TypeError: Error, Sendable, CustomStringConvertible { public let description: String; public init(_ message: String) { description = message } }
open class LM15Error: Error, @unchecked Sendable, CustomStringConvertible {
    open class var errorCode: String { "provider" }
    public let message: String
    public let metadata: JSONValue
    public var code: String { type(of:self).errorCode }
    public var className: String { String(describing:type(of:self)) }
    public var description: String { message }
    public var retryable: Bool { ["rate_limit","timeout","server","transport","lock_timeout"].contains(code) }
    public var partialResponse: Response? { try? Response(json:metadata["partial_response"]) }
    public var providerCode: String? { metadata["provider_code"].isNull ? nil : metadata["provider_code"].s }
    public required init(_ message: String, metadata: JSONValue = [:]) { self.message = message; self.metadata = metadata }
    public func toJSON() -> JSONValue { metadata.merging(["type":.string(className),"code":.string(code),"message":.string(message)]) }
}
open class TransportError: LM15Error, @unchecked Sendable { public override class var errorCode: String { "transport" } }
open class LockTimeoutError: LM15Error, @unchecked Sendable { public override class var errorCode: String { "lock_timeout" } }
open class StreamAssemblyError: LM15Error, @unchecked Sendable { public override class var errorCode: String { "stream_assembly" } }
open class ConfigurationError: LM15Error, @unchecked Sendable { public override class var errorCode: String { "not_configured" } }
open class NotConfiguredError: ConfigurationError, @unchecked Sendable { public override class var errorCode: String { "not_configured" } }
open class UnknownModelError: ConfigurationError, @unchecked Sendable { public override class var errorCode: String { "unknown_model" } }
open class AmbiguousModelError: ConfigurationError, @unchecked Sendable { public override class var errorCode: String { "ambiguous_model" } }
open class CapabilityError: LM15Error, @unchecked Sendable { public override class var errorCode: String { "unsupported_feature" } }
open class UnsupportedFeatureError: CapabilityError, @unchecked Sendable { public override class var errorCode: String { "unsupported_feature" } }
open class ProviderError: LM15Error, @unchecked Sendable { public override class var errorCode: String { "provider" } }
open class AuthError: ProviderError, @unchecked Sendable { public override class var errorCode: String { "auth" } }
open class BillingError: ProviderError, @unchecked Sendable { public override class var errorCode: String { "billing" } }
open class RateLimitError: ProviderError, @unchecked Sendable { public override class var errorCode: String { "rate_limit" } }
open class InvalidRequestError: ProviderError, @unchecked Sendable { public override class var errorCode: String { "invalid_request" } }
open class ContextLengthError: InvalidRequestError, @unchecked Sendable { public override class var errorCode: String { "context_length" } }
open class UnsupportedModelError: InvalidRequestError, @unchecked Sendable { public override class var errorCode: String { "unsupported_model" } }
open class TimeoutError: ProviderError, @unchecked Sendable { public override class var errorCode: String { "timeout" } }
open class ServerError: ProviderError, @unchecked Sendable { public override class var errorCode: String { "server" } }
public typealias RequestTimeoutError = TimeoutError
func errorFromCode(_ code: String, _ message: String, _ metadata: J = [:]) -> LM15Error {
    let classes: [LM15Error.Type] = [TransportError.self, LockTimeoutError.self, StreamAssemblyError.self, NotConfiguredError.self, UnknownModelError.self, AmbiguousModelError.self, UnsupportedFeatureError.self, ProviderError.self, AuthError.self, BillingError.self, RateLimitError.self, InvalidRequestError.self, ContextLengthError.self, UnsupportedModelError.self, TimeoutError.self, ServerError.self]
    return (classes.first { $0.errorCode == code } ?? ProviderError.self).init(message, metadata: metadata)
}
