import Foundation
import LM15

@main struct OfflineExample {
    static func main() async throws {
        let lm = try AnthropicLM(apiKey:"offline-placeholder",env:[:])
        let request = try Request(
            model:"claude-sonnet-4-5",
            messages:[.user("Compare Swift structs and classes.")],
            system:"Give a short explanation.",
            config:Config(maxTokens:256,temperature:0.2)
        )
        // Builds a request without sending it; no provider account is required.
        let wire = try await lm.buildRequest(request)
        let safe = try wire.normalized().without(["headers"])
        FileHandle.standardOutput.write(Data((try safe.jsonString()+"\n").utf8))
        let canonical = try Request.fromJSON(request.toJSONString())
        precondition(canonical == request)
    }
}
