# lm15 for Swift (early port)

lm15 is one request and response model for every major AI model provider:
write a request once and send it to OpenAI, Anthropic, Gemini, xAI, Groq,
DeepSeek, OpenRouter, a cloud or a local model, by changing the model
string. Each language implements it separately and is graded by one shared
[contract](https://github.com/lm15-dev/lm15-contract).

**Early port, not published.** Written against the lm15 contract of
2026-09-11 (`cfed007`, in `CONTRACT_PIN`), where it passed every check on
Linux with Swift 6.2.4: 1,380 of 1,380 in 16 directions. Apple platforms
are declared but were not run. It has not been updated since, and the
contract has grown (sign-in, judgments, ordered JSON checks, new
providers).

lm15 is released in [Python](https://github.com/lm15-dev/lm15-python) (1.0.1, stable),
[TypeScript](https://github.com/lm15-dev/lm15-ts), [Rust](https://github.com/lm15-dev/lm15-rs)
and [Go](https://github.com/lm15-dev/lm15-go) (release candidates). Guides:
[lm15.dev](https://lm15.dev/docs/). For production, use one of those.

## What's here

Swift 6.2 or newer (macOS 15, iOS 18, tvOS 18, watchOS 11 declared; Linux
run): the router, the four provider dialects, streaming, tools, errors,
credentials and cloud credential chains, files, batches, caches, media
generation, video and realtime sessions. Dependencies: SwiftNIO and
NIOSSL (Linux WebSockets) and Swift Crypto.

## Try it

```swift
// Package.swift
.package(url: "https://github.com/lm15-dev/lm15-swift", branch: "main"),
// target dependency: .product(name: "LM15", package: "lm15-swift")
```

```swift
import LM15

let router = try LMRouter()   // keys from the environment
let request = try Request(
    model: "anthropic:claude-haiku-4-5",
    messages: [.user("What eats acorns at night?")]
)
print(try await router.complete(request).text ?? "")
```

```sh
swift build && swift test
swift run LM15Example   # builds a request offline and prints its body
```

## Conformance

```sh
python3 tools/check_contract.py --contract /path/to/lm15-contract --direction all
```

The full guide written with this port, with every API and its stated
differences from the Python reference: [docs/guide.md](docs/guide.md).

## License

See [LICENSE](LICENSE).
