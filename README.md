# fusion-event

macOS-native **reactive event daemon** — the Fusion ecosystem's perception layer.

Turns passive "wait for User Prompt" into "sense system events → trigger Agent Swarm".
Listens to macOS system-level events (file / process / clipboard / network), normalizes them,
filters through a Rule Engine (debounce + throttle + glob), and emits Agent Task triggers
to downstream daemons (`fusion-agent-studio`), with permission audit (`fusion-guard`) and
historical context (`fusion-memory`) on the path.

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

Tests: 39 unit tests, all passing (`swift test`).

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
```

Daemon lifecycle (matches monorepo `start.sh` convention):

```bash
./start.sh start    # launch daemon (nohup, release binary or debug)
./start.sh stop     # graceful stop (launchd-aware if installed, else nohup)
./start.sh status   # pid, socket, rss (launchd-aware)
./start.sh log [-f] # tail daemon log
./start.sh doctor   # health check: socket / event.health RPC / rules.db
./start.sh install  # install as launchd agent (KeepAlive, RunAtLoad, crash-restart)
./start.sh uninstall # remove launchd agent
```

`start`/`stop` run the daemon ad-hoc via `nohup` (PID file). `install`/`uninstall` manage a
launchd agent (`~/Library/LaunchAgents/com.fusion.event.plist`, `KeepAlive=true`) for residency
and automatic crash-restart — use one mode, not both. `stop`/`status` detect the launchd-managed
process automatically.

Runtime data lives in `~/.fusion-event/` (`config.json`, `rules.db`, `launchd.log`, `events.log`).

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
                     │ EventBus │ ◄────────── AsyncStream (bufferingNewest 1024)
                     └────┬─────┘
                          ▼
                   ┌─────────────┐  glob + type match
                   │ RuleEngine  │  debounce / throttle
                   └────┬────────┘
                        │ TriggerSignal (idempotencyKey = SHA256(rule|type|path|bucket))
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

- `AuditBridge` → `guard.audit` over UDS. Outcomes: `pass` / `block` / `challenge` /
  `degradedFailOpen` (guard down + `require_guard=false`) / `failClosed` (guard down + `require_guard=true`).
- `ContextBridge` → `memory.retrieve_context`. On timeout/not-running: stale-cache or empty fallback (H4 degrade).
- `Dispatcher` → `task.submit` to `fusion-agent-studio`. No retry on failure (R3).

### Reliability mechanisms

- **Token bucket** (`tokenBucketMax`): bounds concurrent trigger chains; excess queues, queue>50 drops oldest (R1).
- **Idempotency** (H1): `idempotencyKey = SHA256(rule_name | event_type | target_path | bucket)`,
  `bucket = timestamp / debounceMs`. Key recorded at trigger intake → duplicate signals suppressed.
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
| `guardSock` | `/tmp/fusion-guard.sock` | fusion-guard UDS (guard.audit) |
| `memorySock` | `/tmp/fusion-memory.sock` | fusion-memory UDS (memory.retrieve_context) |
| `outboundTimeoutGuard/Memory/Dispatch` | 2 / 3 / 5 sec | per-bridge RPC timeout |
| `tokenBucketMax` | 5 | max concurrent trigger chains |
| `heartbeatIntervalSec` / `heartbeatDeadSec` | 15 / 45 | IPC heartbeat + dead-conn reap |
| `contextCacheTtlSec` | 60 | context bridge cache TTL |

---

## RPC API (JSON-RPC 2.0 over UDS, NDJSON-framed)

Every line is one JSON-RPC message (`\n` delimited).

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
public enum SystemEventType: String, Codable {
    case fileModified
    case processTerminated
    case clipboardChanged
    case networkStatusChanged
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
`ESXPCTests` (Phase-2 L1 XPC channel), `MultiNodeTests` (H2 multi-node + 2000-event stress/backpressure/idempotency/token-bucket).

---

## Ecosystem references

- PRD (authoritative): `../architecture/fusion-event-prd-0826.md`
- Union architecture: `../architecture/fusion-union-architecture.md`
- Downstream: `../fusion-agent-studio`, `../fusion-guard`, `../fusion-memory`, `../fusion-executor`
- Docs: `docs/api.md` (RPC API), `docs/integration.md` (downstream contracts), `docs/glob-spec.md` (path glob E1)
