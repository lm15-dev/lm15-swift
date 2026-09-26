> This was the README of lm15 for Swift until 2026-09-26. It describes the port as it was written against contract `cfed007` (2026-09-11).

# LM15 for Swift

A native Swift implementation of LM15, pinned to contract `cfed00771dffef2a218b5549151950bf5060ca06`. It provides the full canonical surface and all 16 conformance directions: chat, streaming, tools, reasoning, multimodal input, routing, authentication, models, files, caches, batches, image/speech/video generation, live sessions, and Chat Completions migration.

The package has no Python, Ruby, or TypeScript runtime dependency. Swift implements the SDK, JSON mappings, cryptography integration, and concurrency. A small C target handles POSIX credential subprocesses. Foundation provides HTTP and Apple WebSockets; SwiftNIO and NIOSSL provide Linux WebSockets; Swift Crypto provides SHA/HMAC/RSA. Dependencies and their revisions are recorded in `Package.resolved`.

## Install

Requires Swift 6.2 or newer. Declared Apple deployment targets are macOS 15, iOS 18, tvOS 18, and watchOS 11; Linux is supported. Only Linux with Swift 6.2.4 was executed during development. Apple validation is configured in CI and remains a release gate.

This directory is a standalone Swift package. Move it intact to `lm15-dev/lm15-swift` when that repository is created. Until then, use a local package dependency:

```swift
.package(path: "../lm15-swift")
```

Add `.product(name: "LM15", package: "lm15-swift")` to your target's dependencies, or open this directory's `Package.swift` in Xcode.

```sh
swift build
swift test
swift run LM15Example
```

The example builds a request offline and prints its body without credentials.

## Quick start

```swift
import LM15

let router = try LMRouter() // resolves the provider's environment/credential policy
let request = try Request(
    model: "anthropic:claude-sonnet-4-5",
    messages: [.user("Explain value semantics in one paragraph.")],
    config: Config(maxTokens: 256)
)
let response = try await router.complete(request)
print(response.text ?? "")
print(response.usage.inputTokens as Any) // nil means unreported
```

Direct providers use the same request and response types:

```swift
let lm = try OpenAIChatLM(apiKey: "your-api-key")
let request = try Request(model: "gpt-4.1", messages: [.user("Hello")])
let stream = lm.responseStream(request)
do {
    for try await text in stream { print(text, terminator: "") }
    let response = try await stream.response()
    print(response.finishReason)
} catch {
    await stream.close()
    throw error
}
```

`stream(request)` yields canonical `StreamEvent` values. `ResponseStream` yields text, exposes `.events`, and assembles `.response()`. Use one active consumer. Call `close()` when stopping early, or cancel the task that is consuming it. A missing end event or unnamed streamed tool raises `StreamAssemblyError`; inspect `partialResponse`. Transport cleanup failures after a completed answer appear in `cleanupErrors`.

## Tools and canonical values

```swift
let lookup = try FunctionTool(
    name: "weather",
    description: "Get the weather for a city",
    parameters: ["type": "object", "properties": ["city": ["type": "string"]],
                 "required": ["city"]]
)
let request = try Request(model: "gpt-4.1", messages: [.user("Weather in Oslo?")],
                          tools: [.function(lookup)])
// Execute response.toolCalls yourself, append response.message and a tool result,
// then call complete again. The SDK never executes model-selected functions.
let result = try Message.tool(id: "call-id", text: "12 °C, clear")
```

75 immutable canonical structs expose validated, labeled initializers and camelCase properties. Nine associated-value enums close the part, tool, credential, stream, and live-event unions. Every value conforms to `Sendable`, `Equatable`, and `Codable`.

Use `value.toJSON()`, `value.toJSONString()`, and `Request.fromJSON(text)` for canonical JSON. Wire keys remain snake_case. `JSONValue` preserves integer/float distinctions, 64-bit integers, nulls, and nested opaque data. Standard `JSONEncoder` may choose a different numeric spelling (for example `1` for `1.0`); use `toJSONString()` when byte/type-preserving canonical JSON matters. Response provider data is opt-in: `response.toJSON(includeProviderData: true)`.

## Credentials, cloud hosts, and routing

All provider constructors accept `apiKey`, a typed `credential`, or a `credentialProvider` closure, plus `baseURL`, `compat`, `settings`, `env`, `credentialsPath`, `clock`, and `transport`. Use only one explicit credential source. A credential closure is called once at each request build and its result is never cached. An explicit empty key fails instead of falling back to another account.

```swift
let lm = try AnthropicLM(credentialProvider: {
    .apiKey(try ApiKey(value: await secretStore.readKey()))
})
let router = try LMRouter(config: RouterConfig(
    apiKeys: ["openai": "key", "anthropic": "key"],
    settings: ["vertex": ["project": "my-project", "location": "us-central1"]]
))
```

The `secretStore` above stands for your own secret source; no secret-store service is bundled. Provider environment keys and supported operations are listed in [docs/providers.md](providers.md). Named local compatibility presets choose their own server address; presets without a known address require `baseURL`.

Routing follows explicit `provider:model`, then catalog/aliases, then rules. Unknown and ambiguous models are typed errors. `ModelRegistry` and `RouteRule` allow application-owned catalogs and routing rules.

`explainAuth` is an offline doctor: it reports source selection without invoking credential callbacks, command helpers, or network services. `Auth.getOAuth` loads and refreshes borrowed Claude Code/Codex credentials and xAI's local store. Refreshes lock across processes, re-read under the lock, preserve unrelated fields, and atomically replace files with mode 0600. `CredentialFileStore` exposes locked writes and deletes. `Auth.generatePKCE()` and xAI's device authorization/polling/login flow are public. `Auth.login` presents the verification URL/code through your callback; it never launches a browser automatically.

AWS chains include bearer/static environment values, profiles, role and web identity STS, SSO/login caches, credential_process, container credentials, and IMDSv2. Azure supports environment secrets/certificates, workload identity, managed identity, and configured CLI sources. Google supports ADC service accounts, authorized users, external accounts, impersonation, metadata, and gcloud. Token refreshes coalesce per adapter. Metadata and credential helpers run only when selected by the configured cloud chain.

## Files, caches, jobs, and media

| Operation | Swift API |
|---|---|
| Models | `listModels()` |
| Files | `fileUpload`, `fileGet`, `fileList`, `fileDownload`, `fileDelete` |
| Caches | `cacheCreate`, `cacheGet`, `cacheUpdate`, `cacheList`, `cacheDelete` |
| Cached prefix | `cache(prefix)` → `CachedPrefix`; `prefix.request("suffix")` |
| Batches | `batch(requests)` → `BatchJob`; `batchJob(id)`, `batches()` |
| Batch handle | `info`, `status`, `done`, `refresh`, `wait`, `results`, `cancel` |
| Images / speech | `generateImage(ImageGenerationRequest)`, `generateSpeech(SpeechGenerationRequest)` |
| Video | `videoGenerate(VideoGenerationRequest)` → `VideoJob`; `videoJob`, `videoJobs` |
| Video handle | `info`, `status`, `done`, `refresh`, `wait`, `result` |

Handles are actors. Reading their state never contacts a provider. `wait(pollEvery:timeout:)` uses seconds, a monotonic deadline, and Swift task cancellation. Low-level endpoint builders/parsers and `batchSubmit`, `batchStatus`, `batchResults`, `submitVideo`, `videoStatus`, and `videoResult` remain public. Provider capability policies reject unsupported operations before sending.

## Live sessions

```swift
let lm = try OpenAILM(apiKey: "your-api-key")
try await lm.withLiveSession(LiveConfig(model: "gpt-realtime")) { session in
    try await session.sendText("Hello")
    let turn = try await session.turn().result()
    print(turn.text)
    // A tool_call boundary returns control to your application to run the tool.
}
```

`LiveSession` sends text, audio `Data`, images, turns, and tool results; it supports interrupt, endAudio, receive, and async event iteration. Only one receiver may be active; sends serialize. `TurnView` preserves boundaries and exposes both a snapshot and a materialized `Turn`, including usage and raw audio. Mixed audio media types are refused.

`live(config, connect:)` accepts a `LiveConnector` returning your own `LiveSocket`. Defaults use URLSession on Apple and NIO/NIOSSL on Linux. Linux verifies TLS hostnames/certificates, validates WebSocket upgrade responses, masks outgoing frames, handles control/fragmented frames, and bounds frame, message, and queued-message bytes. The default message/buffer bound is 16 MiB. HTTP stream buffers are also bounded; overflow raises an error.

## OpenAI Chat Completions migration

`requestFromOpenAIChat(body, compat:)` converts a Chat Completions body into a canonical `Request`; `responseFromOpenAIChat(body, model:choice:)` reuses the normal response parser. The provider method uses that adapter's compatibility policy.

The router exposes `requestFromOpenAIChat(body)` → `(request, adapter)`, `completeFromOpenAIChat(body)`, `streamFromOpenAIChat(body)` for events, and `responseStreamFromOpenAIChat(body)` for text plus the assembled answer. `openAIChatModelString` handles registered `provider/model` migration prefixes. Bare OpenAI model names use Chat Completions on this migration path. Client configuration keys are refused with `RouterConfig` named as their destination.

## Stated deviations

These correspond to the pinned contract's `playbooks/api-family.md` and port rules.

- Async operations use native `async throws`, actors, and `AsyncSequence`; there are no separate Async-prefixed classes or blocking wrappers. Every constructor field has a Swift argument label. Validation throws `ValueError` / `TypeError`; provider errors preserve the canonical class hierarchy and codes.
- JSON uses the package's lossless `JSONValue`, not `[String: Any]`. Structs are immutable owned values; updates construct a replacement (or `Request.with`). Credential strings, values, and callbacks have separate labeled constructor arguments to make their types explicit.
- Tools use explicit JSON schemas. Swift function reflection does not derive tool schemas. There is no automatic tool execution.
- Migration helpers take one JSON body; streaming has separate statically typed methods, not a boolean-selected union return. `completeFromOpenAIChat` rejects `stream: true`. `Auth` contains login/PKCE functions; `explainAuth` is the module-level doctor.
- Canonical JSON emission is `toJSONString()`; Foundation's encoder alone cannot promise the contract's integer/float spelling. Missing usage is optional, never synthesized zero.
- Swift Crypto is a runtime dependency for cross-platform RSA and signing. Linux adds SwiftNIO/NIOSSL because Foundation WebSocket support depends on the system curl build. The small native C process helper avoids invoking a shell and bounds time/output. Process-based credential rungs are unavailable on Apple mobile platforms; explicit credentials and HTTP-based chains remain available. Windows is not supported.
- The reference's explicit provider limits remain: Bedrock AWS event-stream framing, Google external-account AWS subject-token generation, and Service Fabric identity's special TLS pinning are refused. The port does not claim these unimplemented provider doors are supported. Encrypted certificate keys are refused. Optional legacy `ProviderProfile` APIs and a loopback OAuth callback listener are absent; no owned login flow requires that listener.
- Job polling timeout is the package's `TimeoutError`. Exact byte canonicalization requires the canonical APIs. Apple builds and real provider sessions still need validation before a release tag.

## Validation and development

[CONFORMANCE.md](../CONFORMANCE.md) records the exact test gates, pins, totals, and limitations. [docs/api-review.md](api-review.md) maps the public family surface. No fixture, golden, vector, comparator, or existing skip was changed. Generated declarations have compiler-checked key paths; `Surface.dump()` reports actual Swift properties and enum cases.

```sh
swift test
python3 tools/check_contract.py --contract /path/to/clean/pinned/lm15-contract --direction all
python3 tools/differential.py --python-repo /path/to/pinned/lm15-python
```

`tools/export_reference_data.py` exports declarations from the pinned Python source; `tools/generate_types.py` produces Swift types, errors, provider constructors, and field metadata. These are development tools only. The runtime never reads the contract corpus.

The CI workflow runs the native tests, original contract harness, and differential checks on Linux and macOS. Staged in the contract repository, the root Swift-port workflow handles the nested path; copied to its own repository, the package's workflow handles the root path. No provider keys are needed for tests. MIT licensed; dependencies retain their own licenses.
