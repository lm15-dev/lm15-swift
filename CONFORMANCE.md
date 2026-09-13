# Conformance record

Validated on Linux x86_64 with Swift 6.2.4 on 2026-09-12.

Contract: `cfed00771dffef2a218b5549151950bf5060ca06` (also `CONTRACT_PIN`).
Python: `3bbbd3ee1bab40a1a61cc74db120c4a8eb7eb22b`.
TypeScript: `b1ab0df64f0608d790570db32a32860b2a48c8fd`.

## Original shared harness

| Direction | Passed | Failed | Skipped |
|---|---:|---:|---:|
| request | 366 | 0 | 1 |
| response | 302 | 0 | 1 |
| stream | 40 | 0 | 0 |
| error | 84 | 0 | 0 |
| serde | 115 | 0 | 0 |
| auth | 43 | 0 | 0 |
| token | 43 | 0 | 0 |
| models | 34 | 0 | 0 |
| live | 24 | 0 | 0 |
| files | 48 | 0 | 0 |
| batch | 41 | 0 | 0 |
| generation | 20 | 0 | 0 |
| video | 27 | 0 | 0 |
| cache | 11 | 0 | 0 |
| router | 22 | 0 | 0 |
| ingest | 160 | 0 | 0 |
| **Total** | **1380** | **0** | **2** |

The two existing skips are `openai.computer_use`: no canonical request for request checking and no response golden. This port adds no skips. No corpus case, body, golden, vector, comparator, or harness source was edited. The wrapper supplies only a temporary language registration and requires a clean oracle checkout at the exact pin. Runtime code uses declaration resources, never fixture answers. `Surface.dump()` obtains field names from compiler-checked key paths to actual Swift properties and vocabularies from enum cases.

## Native and differential checks

29 native XCTest tests passed with zero failures. They cover typed values, Unicode and integer/float preservation, large integer overflow rejection, cached-prefix boundaries, routing and migration, callback credential timing, SSE line fragmentation/limits, stream cancellation/partial answers/cleanup, live turn boundaries, atomic file refresh with concurrent callers, file permissions and lock contention, cloud token exchanges and cache expiry, process timeout/cancellation, device polling/PKCE, local HTTP transport, and native WebSocket upgrade/control/fragmented/malformed frames.

28 of 28 novel differential requests match Python. The independent generator reads no corpus files. Requests, reference revision, and any mismatches are retained in `docs/differential.json`. They combine Unicode, tools, tool choice, structured output, history, sampling, streaming, and migration across four dialects.

The offline Swift example builds and roundtrips a request with no credentials or live calls. All package sources compile with Swift 6 concurrency checking. `docs/validation.json` is the machine-readable summary; `docs/native-tests.log` is the native run output.

## Reproduce

```sh
swift test
swift run LM15Example
python3 tools/check_contract.py --contract /path/to/clean/pinned/lm15-contract --direction all
python3 tools/differential.py --python-repo /path/to/pinned/lm15-python
```

For the constrained authoring runtime, SwiftPM used `--use-integrated-swift-driver -j 2`. The final SwiftPM build completed; its spawned test runner hit an intermittent environment process-inspection trap (`/proc/.../stat`). Running the same built XCTest executable directly completed all 29 tests successfully. Earlier SwiftPM-driven runs also passed. Ordinary hosts can use the commands above. The configured CI covers Linux and macOS; it has not yet run on GitHub. Apple deployment targets use the modern actor-isolated iterator APIs (macOS 15 / iOS 18 / tvOS 18 / watchOS 11).

## Validation limits

`unshare -rn` was unavailable, so the harness reported `sandboxed: false`. Contract operations and injected transports ran offline; native network tests used loopback sockets. No paid/provider API, real cloud metadata, interactive OAuth authorization, or live provider WebSocket was exercised. The TLS client uses NIOSSL's default trust and hostname verification; a live TLS/provider interoperability run remains outstanding. macOS/iOS/tvOS/watchOS builds and per-port mutation tests were not executed in this environment. These are release risks, not hidden skips.

See the README's stated deviations and `docs/api-review.md`. Corpus compatibility is evidence against this pin, not live certification or independent maintainer approval.
