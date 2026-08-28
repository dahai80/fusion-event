# fusion-event — Architecture

System design: event sources, pipeline, reliability, source layout.

## Overview

`fusion-event` is a macOS-native **reactive event daemon** — the Fusion ecosystem's perception layer. It turns passive "wait for User Prompt" into "sense system events → trigger Agent Swarm": it listens to macOS system-level events (file / process / clipboard / network), normalizes them, filters through a Rule Engine (debounce + throttle + glob), and emits Agent Task triggers to downstream daemons, with permission audit (`fusion-guard`) and historical context (`fusion-memory`) on the path.

- **Language**: Swift 6 (strict concurrency, `actor`-isolated throughout).
- **IPC**: JSON-RPC 2.0 over Unix Domain Socket, NDJSON-framed (one message per `\n`).
- **Storage**: SQLite (WAL) for rules + debounce state; rolling JSONL event log.
- **Logging**: `os.Logger` (Apple unified logging, subsystem `com.fusion.event`).
- **Local-only**: every socket is UDS on `127.0.0.1`/`$TMPDIR`; no cross-node TCP. `nodeId` is carried in every event/signal/log line for traceability.

## Event pipeline

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

Raw events flow in → EventBus → RuleEngine (match + filter) → Normalizer → Dispatcher → three outbound bridges (guard audit, memory context, task submit).

## Event sources

| Source | API | Events | Notes |
|--------|-----|--------|-------|
| FSEvents | `FSEventStream` | `fileModified` | watch `fseventsRoot` (default `$HOME`); whitelist-aware |
| NSWorkspace | `NSWorkspaceNotificationCenter` | `processLaunched`, `processTerminated`, `systemWake`, `systemSleep` | always registered; low-fidelity process events (app launch/terminate) |
| NWPathMonitor | `NWPathMonitor` | `networkStatusChanged` | Wi-Fi/Ethernet up/down |
| Pasteboard | `NSPasteboard` poll | `clipboardChanged` | poll interval configurable |
| EndpointSecurity | `es_new_client` | privileged process exec/exit/fork | disabled by default (needs entitlement); fail-closed degrade to NSWorkspace |

All sources implement the `EventSource` actor protocol and are managed by `SourceRegistry` (start/stop lifecycle).

## Rule engine

`RuleEngine` matches each `RawEvent` against rules (glob `path_pattern` + `event_type`), then applies:

- **Debounce** (`debounce_ms`): drop repeats of the same rule+path within a window.
- **Throttle** (`throttle_ms`): at most one fire per window (N-per-window).
- **Monotonic dedup** (high-water): never re-fire for an older timestamp.

Debounce state persists to SQLite WAL on every fire; on restart it rebuilds the last-60s window from `events.log` (double-coverage so a lost WAL write is still backed by the event log).

## Dispatcher + bridges

`Dispatcher` fans each `TriggerSignal` to three outbound bridges through a **token bucket** (`tokenBucketMax`, bounds concurrent trigger chains; excess queues, queue > 50 drops oldest) and a **crash-safe outbox** (atomic + fsync write, replayed on restart):

- **AuditBridge** → `guard.audit` over UDS (socket `guardSock`). Sends trigger_id/event_type/target_path/target_agent/payload/node_id/tenant_id; parses `AuditDecision` {decision: pass|block|challenge, reason, risk_level, audit_id}. Degrade: `require_guard=false` → fail-open; `require_guard=true` → fail-closed.
- **ContextBridge** → `memory.retrieve_context` over UDS (socket `memorySock`). Bounded LRU cache (TTL `contextCacheTtlSec`); on timeout falls back to stale cache or empty.
- **Dispatcher** → `task.submit` to `fusion-agent-studio` (socket `studioSock`), `input.event` in snake_case. No retry on failure.

## Reliability mechanisms

- **Idempotency** (H1): `idempotencyKey = SHA256(nodeId | rule_name | event_type | target_path | bucket)`, `bucket = timestamp / debounceMs`. Node-scoped (keys never cross-suppress across nodes). Failed `task.submit` marks the key so restart replay doesn't re-submit.
- **Crash-safe outbox** (R4): trigger signals are written atomically + fsync'd before dispatch; replayed on restart. Failed replay keeps the entry (no silent delete).
- **3-state degrade**: each bridge handles `connectionFailed` / `timeout` / `ioError` with fail-open-or-fail-closed per rule's `require_guard`.
- **Backpressure**: bounded `AsyncStream` (8192) between ingest and dispatch; overflow drops are counted and surfaced via metrics, never silent.
- **Heartbeat** (E6): IPC server pushes `event.heartbeat` every 15s; clients reply `event.pong`; connections silent beyond 45s are reaped.

## IPC

JSON-RPC 2.0 over UDS (`sockPath`, default `/tmp/fusion-event.sock`), NDJSON-framed. Supports batch requests (array → array reply; notifications get no response, per spec). Socket is 0600 + peer-uid authenticated. Server pushes `event.notification` (raw events to subscribers) and `event.heartbeat`. See [API reference](api.md) for the full method set.

## Source layout

```
Sources/fusion-event/
├── main.swift            # top-level wiring + lifecycle loop
├── Types.swift           # SystemEvent, EventRule, TriggerSignal, RawEvent
├── Config.swift          # FusionEventConfig (config.json)
├── Logging.swift         # os.Logger (com.fusion.event)
├── Lifecycle.swift       # actor Lifecycle + signal handlers
├── EventBus.swift        # AsyncStream pub/sub + backpressure
├── Metrics.swift         # MetricsCollector actor + LatencyHistogram
├── RuleEngine.swift      # match + debounce + throttle
├── RuleStore.swift       # SQLite rules + debounce state (WAL)
├── Normalizer.swift      # RawEvent → TriggerSignal (+ idempotency key)
├── EventLog.swift        # rolling JSONL event log
├── Glob.swift            # glob matcher
├── RPC.swift             # AnyCodable + JSON-RPC codec
├── UDSClient.swift       # outbound UDS RPC client + withTimeout
├── sources/              # EventSource protocol + SourceRegistry + concrete sources
├── bridges/              # AuditBridge, ContextBridge, Dispatcher
└── ipc/                  # IPCServer (UDS JSON-RPC server), RPCMethods
```
