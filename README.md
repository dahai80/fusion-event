# fusion-event

macOS-native **reactive event daemon** — the Fusion ecosystem's perception layer.

Turns passive "wait for User Prompt" into "sense system events → trigger Agent Swarm".
Listens to macOS system-level events (file / process / clipboard / network), normalizes them,
filters through a Rule Engine (debounce + throttle + glob), and emits Agent Task triggers
to downstream daemons (`fusion-agent-studio`), with permission audit (`fusion-guard`) and
historical context (`fusion-memory`) on the path.

> **Status: `0.1.0-rc.2`** — second release candidate. Upstream contract alignment (guard.evaluate / retrieve_context / task.submit snake_case) so all three integration chains work end-to-end; CI + swift-format lint gate added. ES entitlement + release signing still pending (see CHANGELOG.md + docs/release-signing-checklist.md).

- **Language**: Swift 6 (strict concurrency, `actor`-isolated).
- **IPC**: JSON-RPC 2.0 over Unix Domain Socket, NDJSON-framed.
- **Storage**: SQLite (WAL) for rules + debounce state; rolling JSONL event log.
- **Logging**: `os.Logger` (unified logging, subsystem `com.fusion.event`).

---

## Status

M0–M4 implemented and verified:

| Milestone | Scope | State |
|-----------|-------|-------|
| M0 | SPM skeleton, `SystemEvent`/`EventRule` contracts, UDS JSON-RPC server, bridges, `start.sh` | done |
| M1 | Event sources (FSEvents / NSWorkspace / NWPathMonitor / Pasteboard), EventBus, RuleEngine, Normalizer, `rule.*` RPC | done |
| M2 | AuditBridge + ContextBridge wired, 3-state timeout degrade, token bucket, idempotency LRU | done |
| M3 | EndpointSecurity privileged process events (exec/exit/fork) | in-process + degrade — esEnabled flag, fail-closed to NSWorkspace |
| M4 | Ecosystem hardening: multi-node boundary (H2), 2000-event stress + backpressure (H5), idempotency collapse (H1), token-bucket drain (R1), docs (API + integration + glob spec E1) | done — internal-verifiable parts; upstream studio/cli/guard/memory联调 via frozen contract (issue-tracked) |
| M5 | Adversarial audit hardening (P0–P3): F1 socket 0600 + peer-uid auth, F2 ingest/dispatch decouple + bounded backpressure (drop-counted, not silent), F4 ES NULL guard, F5 poisoned-conn reset, F6 fd ownership, F7 config persist, F8 recv OOM cap, F9 idempotency-occupy only on success/block, L1 signal race, L2 LRU+queue cap, L3 N-per-window throttle, L4 wake type, L5 param SQL, L6 FSEvents UAF, L7 shutdown drain, L8 write-all, P1–P3 EventLog perf, M1–M5 | done — see `docs/audit-fixes-0827.md` |
| M6 | Architecture audit hardening (A/R/E): A2 nodeId persist UUID, A3 true ingest decouple (bounded stream + `drainIngest`), A4 ContextBridge LRU bound, A6/R3 monotonic dedup, A10 backpressure回流 (observe/notify), R1 FSEvents whitelist, R2 dispatch capacity configurable, R4 crash-safe outbox + replay, R5 WAL checkpoint, R6/R10 shutdown hard timeout + drain, R7 source throttle, R8 mountObserver registered, R9 EventLog atomic rotate, E1 RuleStore concurrency, E2 UPSERT preserve created_at, E3 migration versioning, E5 buffered recv, E6 maxRetries honored, E8 pasteboard poll configurable | done — see `docs/audit-fixes-0827.md` §第二轮; A1/A7/A8/A9/E4/E7/E9 deferred (design/external/low-pri) |
| M7 | Production-readiness audit hardening (P0–P3): F-CRASH-1 FSEvents concurrent-mutate crash (snapshot flush), F-CRASH-2 outbox failed-replay delete (fail-keep), F-CRASH-3 atomic+fsync write, S0 guard-block no fail-open, P4-1 bounded fan-out, F-1/2/3 source lifecycle+UAF, F-IDEM-1/2 nodeId idempotency + failed-occupy, F-DROP-1 overflow-to-outbox, F-PERSIST-1/2/3/4/5/6 migration+WAL FULL+fsync+archive scan, F-EVICT-1/2 true LRU + O(n) purge, F-TIMEOUT-1 configurable recv timeout, D2/D3 shutdown RPC + real nodeId, S1 0600 files, S3 replay cap, F-5/6/10/11/12/13/15/16 source+IPC fixes, F-EVICT-2, P4-2/4, O4/O5/O8/O9/O10 ops, D5 batch+notification, S4 rule validation | done — see `docs/audit-fixes-0827.md` §第三轮; S5/S6/D4 ES entitlement, A2-3 HA, end-to-end联调 deferred (external) |
| M8 | Release engineering + observability: O1/E9 in-process metrics pipeline (`MetricsCollector` actor, counters + latency histogram P50/P99 + backpressure duration, `event.metrics` RPC), codesign/notarize script (`scripts/sign.sh` + entitlements, hardened runtime, ES entitlement commented pending Apple approval), chaos/long-run stress harness (`StressHarnessTests`, env-gated `FUSION_EVENT_STRESS`, 4 tests: memory-drift / downstream-kill outbox replay / disk-full degrade / concurrent IPC load) | done — see `docs/audit-fixes-0827.md` §第四轮; S5/S6/D4 ES entitlement, A2-3 HA, end-to-end联调 still external (issues #3/#4/#250) |
| M9 | E2E integration smoke (task.submit): env-gated test `E2EStudioTests` connects fusion-event full chain to a **real** agent-studio daemon over UDS, pushes file events, verifies `task.submit` accepted + `task_id` returned (submitted>0, failed==0). Proves socket+params+response contract end-to-end. | done — task.submit `input.event` now snake_case (issue #250 fixed rc.2); guard.evaluate (#3) + retrieve_context (#4) chains contract-verified via MockGuard/MockMemory unit tests rc.2, real-daemon E2E still pending |

Tests: 66 unit tests, all passing (`swift test`), ~2s. 4 stress + 1 E2E skipped by default — stress via `FUSION_EVENT_STRESS=1 swift test --filter StressHarnessTests`; E2E via `FUSION_EVENT_E2E=1 swift test --filter E2EStudioTests` (requires real agent-studio daemon on `/tmp/fusion-studio.sock`).

### Phase-2 — System Extension + XPC (L1 skeleton, contract frozen)

The PRD plan (§9.5) corrects the ES architecture: a faithful EndpointSecurity deployment is a
**separate System Extension process** + XPC relay back to the daemon, not an in-process flag.
Verification tiers:

| Tier | Scope | State |
|------|-------|-------|
| L0 | Xcode System Extension target compiles | blocked — needs SPM→Xcode target |
| L1 | XPC contract skeleton: `ESXPCProtocol` (`@objc`, `NSData` payload) + `ESXPCServer` (anonymous `NSXPCListener`) + `ESXPCMockClient` → EventBus; 3 tests pass zero-auth | **done** |
| L2 | real `es_new_client` SUCCESS in extension process | blocked — needs Apple entitlement |
| L3 | systemextension packaging + notarization + `OSSystemExtensionRequest` install | blocked — needs entitlement + signing |

L1 is the only portable + verifiable part pre-authorization. Enabled by `FUSION_EVENT_ES_XPC_ENABLED=1`
(`config.esXpcEnabled`); daemon starts an anonymous `NSXPCListener`, the (mock now, real later)
extension connects via `NSXPCConnection(listenerEndpoint:)` and delivers `ESSnapshotXPC` as JSON-encoded
`NSData`. When the Apple `endpoint-security.client` entitlement is granted, only the mock swaps to a real
`es_new_client` extension — the XPC contract (`ESXPCProtocol`, `ESSnapshotXPC`) is frozen, zero change.

> **Endpoint transport note:** `NSXPCListenerEndpoint` is only encodable by `NSXPCCoder`, not a generic
> `NSKeyedArchiver` — it cannot be serialized to a file. The real extension acquires the endpoint via
> launchd/xpc bootstrap (L3), not a file. The daemon exposes it in-process via the listener.

---

## Build / Test / Run

```bash
swift build                   # debug
swift build -c release        # release (start.sh prefers release)
swift test                    # unit tests
swift test --filter GlobTests # single suite
# chaos/long-run stress harness (NOT in default swift test, env-gated):
FUSION_EVENT_STRESS=1 FUSION_EVENT_STRESS_ITERS=5000 swift test --filter StressHarnessTests
# E2E integration against REAL agent-studio daemon (env-gated, needs daemon up):
FUSION_EVENT_E2E=1 swift test --filter E2EStudioTests
```

Daemon lifecycle (matches monorepo `start.sh` convention):

```bash
./start.sh start    # launch daemon (nohup, release binary or debug)
./start.sh stop     # graceful stop (launchd-aware if installed, else nohup)
./start.sh status   # pid, socket, rss (launchd-aware)
./start.sh log [-f] # tail daemon log
./start.sh doctor   # health check: socket / event.health RPC / triggers+outbox backlog / rules.db (O5)
./start.sh install  # install as launchd agent (KeepAlive, RunAtLoad, crash-restart)
./start.sh uninstall # remove launchd agent
```

`start`/`stop` run the daemon ad-hoc via `nohup` (PID file). `install`/`uninstall` manage a
launchd agent (`~/Library/LaunchAgents/com.fusion.event.plist`, `KeepAlive=true`) for residency
and automatic crash-restart — use one mode, not both. `stop`/`status` detect the launchd-managed
process automatically.

Runtime data lives in `~/.fusion-event/` (`config.json`, `rules.db`, `launchd.log`, `events.log`).

Log rotation (O4): `start` rotates `launchd.log` at >10MB (keeps `.1`/`.2`/`.3`/`.4`). launchd plist
sets `ThrottleInterval=10` / `ExitTimeOut=15` to avoid restart thrash (O8). `start` warns if a launchd
plist is already installed (nohup + KeepAlive race, O9). `doctor` parses `event.health` via `python3`
JSON (not fragile `nc`/`grep`, O10) and reports `triggers{failed,dropped,dispatch_dropped}` +
outbox backlog (warn >50).

Metrics (O1/E9): in-process `MetricsCollector` actor — counters (source events, trigger
submitted/blocked/failed/dropped/retried, ingest+dispatch drops, outbox backlog), per-bridge
latency histogram (P50/P99/avg/max for guard/memory/dispatch), backpressure active+total duration.
No external deps. Exposed via `event.metrics` JSON-RPC (snapshot returns `AnyCodable`, Sendable).
Drain/clear on demand. Wired into `Dispatcher` + `EventBus` at every counter/latency/pressure site.

Release engineering (M8): `scripts/sign.sh` codesigns + notarizes the release binary for
enterprise distribution (`codesign --options runtime` hardened runtime, `notarytool --wait`,
`stapler staple`). Entitlements in `scripts/fusion-event.entitlements` (network client; ES
entitlement commented out — blocked on Apple approval, ES source stays `esEnabled=false`).
External prereqs the user must provide: Developer ID Application cert (keychain), notarytool
keychain profile, ES entitlement (optional). Run `./scripts/sign.sh` (full) or `sign-only`.

Stress harness (M8, O2): `Tests/fusion-eventTests/StressHarnessTests.swift` — 4 chaos/long-run
tests, env-gated (`FUSION_EVENT_STRESS=1`, skipped in default `swift test`): long-run memory-drift
bounded (RSS start vs end, heuristic 200MB cap), downstream-kill → outbox replay (R4 crash-safe),
disk-full → degrade-no-crash, concurrent IPC client load (taskGroup). `FUSION_EVENT_STRESS_ITERS`
scales iteration count (default 2000).

E2E integration (M9): `Tests/fusion-eventTests/E2EStudioTests.swift` — env-gated
(`FUSION_EVENT_E2E=1`, skipped in default `swift test`), connects fusion-event full chain
(EventBus → RuleEngine → Dispatcher) to a **real** agent-studio daemon over UDS and verifies
`task.submit` accepted + `task_id` returned. Requires real daemon on
`/tmp/fusion-studio.sock` (override via `FUSION_EVENT_E2E_STUDIO_SOCK`). Covers the only
mature chain; guard (#3) + memory (#4) chains await upstream contract alignment.

---

## Architecture

```
┌─────────────┐   ┌─────────────┐   ┌──────────────┐   ┌──────────────┐
│ FSEvents    │   │ NSWorkspace │   │ NWPathMonitor│   │ Pasteboard   │
│ (fileMod)   │   │ (proc term) │   │ (net change) │   │ (clipboard)  │
└──────┬──────┘   └──────┬──────┘   └──────┬───────┘   └──────┬───────┘
       └──────────────────┴─────────────────┴─────────────────┘
                          │ RawEvent
                          ▼
                     ┌──────────┐  backpressure
                     │ EventBus │ ◄────────── AsyncStream (bufferingNewest 8192)
                     └────┬─────┘
                          ▼
                   ┌─────────────┐  glob + type match
                   │ RuleEngine  │  debounce / throttle
                   └────┬────────┘
                        │ TriggerSignal (idempotencyKey = SHA256(nodeId|rule|type|path|bucket))
                        ▼
                    ┌──────────┐
                    │Dispatcher│  token bucket (max N) + pending queue (overflow>50 drops)
                    └────┬─────┘
              ┌──────────┼──────────┐
              ▼          ▼          ▼
        ┌─────────┐ ┌─────────┐ ┌─────────────┐
        │  Audit  │ │ Context │ │ task.submit │
        │  Bridge │ │  Bridge │ │ (agent-     │
        │→ guard  │ │→ memory │ │  studio)    │
        └─────────┘ └─────────┘ └─────────────┘
```

### Event path (ecosystem flow)

```
FSEvents ──► fusion-event ──► fusion-guard (TCC/DLP + injection-risk audit)
                                └─► fusion-event triggers Task + pulls context ──► fusion-memory
                                                                              └─► fusion-agent-studio (task.submit)
```

- `AuditBridge` → `guard.evaluate` over UDS (rc.2: was `guard.audit`, which does not exist upstream). Sends serialized event JSON as `content` with `content_type: "json"`; maps upstream `SafetyAction` (Allow→pass, Preview→challenge, Redact→block, Block→block). Outcomes: `pass` / `block` / `challenge` /
  `degradedFailOpen` (guard down + `require_guard=false`) / `failClosed` (guard down + `require_guard=true`).
- `ContextBridge` → `memory.retrieve_context` over UDS at `~/.fusion-memory/fusion-memory.sock` (rc.2: aligned to upstream path). On timeout/not-running: stale-cache or empty fallback (H4 degrade).
- `Dispatcher` → `task.submit` to `fusion-agent-studio` with `input.event` in snake_case (rc.2: matches `trigger_input.py` frozen contract, issue #250). No retry on failure (R3).

### Reliability mechanisms

- **Token bucket** (`tokenBucketMax`): bounds concurrent trigger chains; excess queues, queue>50 drops oldest (R1).
- **Idempotency** (H1): `idempotencyKey = SHA256(nodeId | rule_name | event_type | target_path | bucket)`,
  `bucket = timestamp / debounceMs`. Key recorded at trigger intake → duplicate signals suppressed.
  Node-scoped (F-IDEM-1): keys never cross-suppress across nodes. Failed `task.submit` marks the key
  with `taskId="failed"` so restart replay doesn't re-submit (F-IDEM-2).
- **Restart window rebuild** (R5): debounce state persisted to SQLite WAL on every fire. On restart,
  `loadFromStore` loads WAL state AND rebuilds the last-60s window from `events.log` (per-rule max ts),
  merging the greater — so even if a WAL write is lost, the event log backs it up (双保险).
- **3-state degrade**: each outbound bridge has `connectionFailed` / `timeout` / `ioError` handling
  with fail-open-or-fail-closed per rule's `require_guard`.
- **Heartbeat** (E6): IPC server sends `event.heartbeat`; dead connections (no `event.pong` within
  `heartbeatDeadSec`) are reaped.

---

## Configuration

`~/.fusion-event/config.json`:

| Key | Default | Meaning |
|-----|---------|---------|
| `sockPath` | `/tmp/fusion-event.sock` | UDS server socket |
| `fseventsRoot` | `$HOME` | FSEvents watch root |
| `esEnabled` | `false` | enable EndpointSecurity source (M3; env `FUSION_EVENT_ES_ENABLED=1`) |
| `esXpcEnabled` | `false` | enable ES XPC server skeleton (Phase-2 L1; env `FUSION_EVENT_ES_XPC_ENABLED=1`) |
| `nodeId` | hostname | Node identity in emitted events |
| `studioSock` | `/tmp/fusion-studio.sock` | agent-studio UDS (task.submit) |
| `guardSock` | `/tmp/fusion-guard.sock` | fusion-guard UDS (guard.evaluate) |
| `memorySock` | `~/.fusion-memory/fusion-memory.sock` | fusion-memory UDS (memory.retrieve_context, rc.2 aligned to upstream) |
| `outboundTimeoutGuard/Memory/Dispatch` | 2 / 3 / 5 sec | per-bridge RPC timeout |
| `tokenBucketMax` | 5 | max concurrent trigger chains |
| `heartbeatIntervalSec` / `heartbeatDeadSec` | 15 / 45 | IPC heartbeat + dead-conn reap |
| `contextCacheTtlSec` | 60 | context bridge cache TTL |

---

## RPC API (JSON-RPC 2.0 over UDS, NDJSON-framed)

Every line is one JSON-RPC message (`\n` delimited). Supports **batch requests** (array of
`RPCRequest` on one line → array of `RPCResponse`; notifications with `id == null` get no response,
per JSON-RPC 2.0 spec — D5). `rule.add` validates `rule_name`/`target_agent` (1–256 chars),
`path_pattern` (≤4096, no control chars — S4).

| Method | Params | Returns |
|--------|--------|---------|
| `ping` | — | `{pong: true}` |
| `event.health` | — | `ok, version, uptime_sec, sources{type:{enabled,events_total,errors}}, triggers{submitted,blocked,failed}, sock, node_id` |
| `event.shutdown` | — | `{ok: true}` (initiates graceful stop) |
| `rule.add` | `{rule_name, event_type, target_agent, path_pattern?, debounce_ms?, throttle_ms?, enabled?, max_retries?, require_guard?, target_graph_id?}` | `{ok, rule_name}` |
| `rule.remove` | `{rule_name}` | `{ok}` |
| `rule.list` | — | `{rules: "[...JSON...]"}` |
| `rule.reload` | — | `{ok, count}` (reload from SQLite) |
| `event.replay` | `{since_ts?, limit?}` | `{events: "[...JSON...]"}` |
| `event.dry_run` | `{since_ts?, limit?}` | `{events: [{event, matched_rules, would_trigger}]}` |
| `event.subscribe` | — | server pushes `event.notification` lines |
| `event.pong` | — | heartbeat reply (no response) |

### Quick client (Python)

```python
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
s.sendall((json.dumps({"jsonrpc":"2.0","id":1,"method":"event.health"}) + "\n").encode())
s.settimeout(3); buf = b""
while b"\n" not in buf: buf += s.recv(4096)
print(buf.decode())
```

### Rule example

```json
{"jsonrpc":"2.0","id":1,"method":"rule.add","params":{
  "rule_name":"swift-watch",
  "event_type":"fileModified",
  "target_agent":"fusion-code",
  "path_pattern":"/Users/dahai/src/**/*.swift",
  "debounce_ms":300,
  "require_guard":true
}}
```

`path_pattern` is glob: `*` matches within a segment, `**` across directories, `?` one non-`/` char.

---

## Core types

```swift
public enum SystemEventType: String, Codable, Sendable {
    case fileModified
    case processLaunched
    case processTerminated
    case clipboardChanged
    case networkStatusChanged
    case systemWake
    case systemSleep
}

public struct SystemEvent: Codable, Sendable {
    public let eventId: String
    public let type: SystemEventType
    public let targetPath: String?
    public let timestamp: UInt64
    public let payload: [String: String]
    public let nodeId: String
}

public struct EventRule: Codable, Sendable {
    public let ruleName: String
    public let eventType: SystemEventType
    public let pathPattern: String?
    public let debounceMs: Int
    public let throttleMs: Int
    public let targetAgent: String
    public let targetGraphId: String?
    public let enabled: Bool
    public let maxRetries: Int
    public let requireGuard: Bool
}
```

---

## M3 — EndpointSecurity (in-process + degrade)

Privileged process exec/exit/fork auditing via `EndpointSecurity`. Implemented **in-process**:
`EndpointSecuritySource` calls `es_new_client` + subscribes to `NOTIFY_EXEC/EXIT/FORK` directly
in the daemon process. Enabled only when `config.esEnabled=true` (default `false`; env
`FUSION_EVENT_ES_ENABLED=1`).

**Degrade (fail-closed):** `es_new_client` returns `ERR_NOT_ENTITLED` / `ERR_NOT_PERMITTED` /
`ERR_NOT_PRIVILEGED` when the binary lacks the ES entitlement, TCC approval, or root. The source
self-disables (`enabled=false`), logs the degrade, and emits no events. `NSWorkspaceSource`
(always registered) continues to cover `processTerminated`, so process events are never lost —
just lower-fidelity (no exec/fork, app launches/terminates only).

> **Phase-2 (not implemented):** the PRD plan (§9.5) corrects the architecture — a faithful
> EndpointSecurity deployment is a **separate System Extension process** + XPC relay back to the
> daemon, not an in-process `es_enabled` flag. That needs an Xcode System Extension target,
> `com.apple.developer.endpoint-security.client` entitlement (Apple application), signing +
> notarization, and `OSSystemExtensionRequest` install. The in-process path here is the
> environment-verifiable subset; the System Extension topology is documented for when entitlement
> is granted. See `../architecture/fusion-event-prd-0826.md`.

---

## Source layout

```
Sources/fusion-event/
├── main.swift            # top-level wiring + lifecycle loop
├── Types.swift           # SystemEvent, EventRule, TriggerSignal, RawEvent
├── Config.swift          # FusionEventConfig (config.json)
├── Logging.swift         # os.Logger (com.fusion.event)
├── Lifecycle.swift       # actor Lifecycle + signal handlers
├── EventBus.swift        # AsyncStream pub/sub + backpressure
├── Metrics.swift         # MetricsCollector actor + LatencyHistogram (O1/E9)
├── RuleEngine.swift      # match + debounce + throttle
├── RuleStore.swift       # SQLite rules + debounce state (WAL)
├── Normalizer.swift      # RawEvent → TriggerSignal (+ idempotency key)
├── EventLog.swift        # rolling JSONL event log
├── Glob.swift            # glob matcher
├── RPC.swift             # AnyCodable + JSON-RPC codec
├── UDSClient.swift       # outbound UDS RPC client + withTimeout
├── sources/              # EventSource (protocol + SourceRegistry), FSEventsSource, NSWorkspaceSource, NetworkSource, PasteboardSource, EndpointSecuritySource (M3), ESXPCServer/ESXPCProtocol/ESXPCMockClient (Phase-2 L1)
├── bridges/              # AuditBridge, ContextBridge, Dispatcher
└── ipc/                  # IPCServer (UDS JSON-RPC server), RPCMethods
```

Tests: `GlobTests`, `NormalizerTests`, `RuleEngineTests`, `DispatcherTests`, `ESTests`,
`ESXPCTests` (Phase-2 L1 XPC channel), `MultiNodeTests` (H2 multi-node + 2000-event stress/backpressure/idempotency/token-bucket),
`RPCBatchTests` (D5 batch/notification decode + F-16 no-silent-crash + F-11 processLaunched),
`MetricsTests` (O1/E9 counters + latency histogram P50/P99 + backpressure duration + Sendable snapshot),
`StressHarnessTests` (M8/O2 env-gated chaos: memory-drift / downstream-kill outbox replay / disk-full degrade / concurrent IPC load),
`E2EStudioTests` (M9 env-gated E2E: real agent-studio daemon task.submit socket+params+response contract).

---

## Ecosystem references

- PRD (authoritative): `../architecture/fusion-event-prd-0826.md`
- Union architecture: `../architecture/fusion-union-architecture.md`
- Downstream: `../fusion-agent-studio`, `../fusion-guard`, `../fusion-memory`, `../fusion-executor`
- Docs: `docs/api.md` (RPC API), `docs/integration.md` (downstream contracts), `docs/glob-spec.md` (path glob E1)
