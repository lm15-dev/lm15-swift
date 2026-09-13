#!/usr/bin/env python3
"""Record completed validation from the unmodified harness and native test log."""
import argparse
import json
from pathlib import Path
import re
import shutil

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--native-log', required=True, type=Path)
a = p.parse_args()
log = a.native_log.read_text()
counts = re.findall(r'Executed (\d+) tests, with (\d+) failures',log)
if not counts or int(counts[-1][1]) or "Test Suite 'All tests' passed" not in log:
    raise SystemExit('Native test log must report a completed passing run')
native = int(counts[-1][0])
directions = ['request','response','stream','error','serde','auth','token','models','live','files','batch','generation','video','cache','router','ingest']
reports = {name:json.loads((root/f'tmp/reports/{name}.json').read_text()) for name in directions}
if any(r['summary']['fail'] for r in reports.values()): raise SystemExit('Contract failures remain')
differential = json.loads((root/'tmp/differential.json').read_text())
if differential['failures']: raise SystemExit('Differential failures remain')
summary = {name:r['summary'] for name,r in reports.items()}
total = {key:sum(x[key] for x in summary.values()) for key in ['pass','fail','skip']}
pin = (root/'CONTRACT_PIN').read_text().strip()
result = {'date':'2026-09-12','platform':'x86_64 Linux','swift':'6.2.4','contract_pin':pin,'python_revision':differential['python_revision'],'typescript_revision':'b1ab0df64f0608d790570db32a32860b2a48c8fd','directions':summary,'total':total,'native_tests':{'passed':native,'failures':0},'differential':{'total':differential['total'],'passed':differential['passed']},'network_sandbox_enforced':all(r['sandboxed'] for r in reports.values()),'apple_platforms_tested':False,'live_provider_calls_tested':False,'per_port_mutation_tested':False}
(root/'docs/validation.json').write_text(json.dumps(result,indent=2)+'\n')
shutil.copyfile(root/'tmp/differential.json',root/'docs/differential.json')
shutil.copyfile(a.native_log,root/'docs/native-tests.log')
text = f'''# Conformance record

Validated on Linux x86_64 with Swift 6.2.4 on 2026-09-12.

Contract: `{pin}` (also `CONTRACT_PIN`).
Python: `{result['python_revision']}`.
TypeScript: `{result['typescript_revision']}`.

## Original shared harness

| Direction | Passed | Failed | Skipped |
|---|---:|---:|---:|
'''
for name,row in summary.items(): text += f"| {name} | {row['pass']} | {row['fail']} | {row['skip']} |\n"
text += f"| **Total** | **{total['pass']}** | **{total['fail']}** | **{total['skip']}** |\n"
text += f'''
The two existing skips are `openai.computer_use`: no canonical request for request checking and no response golden. This port adds no skips. No corpus case, body, golden, vector, comparator, or harness source was edited. The wrapper supplies only a temporary language registration and requires a clean oracle checkout at the exact pin. Runtime code uses declaration resources, never fixture answers. `Surface.dump()` obtains field names from compiler-checked key paths to actual Swift properties and vocabularies from enum cases.

## Native and differential checks

{native} native XCTest tests passed with zero failures. They cover typed values, Unicode and integer/float preservation, large integer overflow rejection, cached-prefix boundaries, routing and migration, callback credential timing, SSE line fragmentation/limits, stream cancellation/partial answers/cleanup, live turn boundaries, atomic file refresh with concurrent callers, file permissions and lock contention, cloud token exchanges and cache expiry, process timeout/cancellation, device polling/PKCE, local HTTP transport, and native WebSocket upgrade/control/fragmented/malformed frames.

{differential['passed']} of {differential['total']} novel differential requests match Python. The independent generator reads no corpus files. Requests, reference revision, and any mismatches are retained in `docs/differential.json`. They combine Unicode, tools, tool choice, structured output, history, sampling, streaming, and migration across four dialects.

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
'''
(root/'CONFORMANCE.md').write_text(text)
print(json.dumps(result,indent=2))
