# Public API family review

Reviewed against `playbooks/api-family.md` at `cfed00771dffef2a218b5549151950bf5060ca06`. This records an implementation review; it is not an independent maintainer approval.

| Family surface | Swift implementation / decision |
|---|---|
| LMRouter / Request / Response | Same names and canonical shape; labeled throwing initializers, actor router |
| complete / stream | Native async completion and canonical async event sequence on router and providers |
| ResponseStream | Text AsyncSequence, events view, response(), close(), partial failure and cleanup errors |
| Message.user / assistant / tool | Same concepts; text or typed parts |
| text / toolCalls / usage / finishReason / message | Properties; unreported usage stays nil |
| Config | Validated immutable struct; same wire vocabulary |
| provider:model | Prefix, catalog, rules; typed unknown/ambiguous errors |
| Direct providers | All registry providers; provider-specific constructors generated from declarations |
| Credential / AccessPolicy / settings | Typed values and callback; explicit labels; immutable policies |
| listModels | Normalized ModelInfo with raw origin and inference metadata |
| requestFromOpenAIChat / responseFromOpenAIChat | Module and provider functions; existing parsers reused |
| Router migration | One-body input; separate event/text streaming methods; client options refused |
| BatchJob / VideoJob | Actors with info/id/status/done/refresh/wait/results or result; batch cancel |
| LiveSession / Turn | Native sockets plus codec; single receiver, serialized sends, tools return control |
| FunctionTool / ToolCallPart | Explicit schema; application executes calls |
| Canonical types / serde | 75 structs, 9 closed sums, lossless JSON, compiler-checked property registry |
| Errors | Canonical class hierarchy and codes; cancellation remains CancellationError |
| Auth / PKCE / login | Auth namespace; borrowed CLI refresh, atomic store, xAI device flow |
| Cloud chains | AWS, Azure, GCP acquisition and signing; documented reference limitations |
| Dependencies / platform idioms | Swift Crypto; Linux NIO/NIOSSL; POSIX C subprocess shim; see README deviations |

The only `send` operation is the transport/live-event operation, not a synonym for core `complete`. Image and speech generation use their separate canonical generation request types. Deprecated provider profiles and automatic function execution are not added.

Native tests found and fixed CRLF parsing across Swift grapheme boundaries, explicit stream-close cancellation, and Linux Foundation WebSocket unavailability. The latter uses the native NIO transport. Reference tests remain unchanged. The independent differential script retains every request's input and every mismatch in its report.
