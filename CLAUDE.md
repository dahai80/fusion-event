# CLAUDE.md

This file gives guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

**`0.1.0-rc.4`** — implemented and released. macOS-native reactive event daemon, Swift 6 strict concurrency (all `actor`-isolated), standalone Swift Package (was extracted from the Fusion monorepo). 71 unit tests passing, 4 integration chains E2E-verified. Repo is public (Apache 2.0).

## What fusion-event Is

A macOS-native **reactive event daemon** — the Fusion ecosystem's perception layer. It turns passive "wait for User Prompt" into "sense system events → trigger Agent Swarm": listens to macOS system-level events (file / process / clipboard / network), normalizes them, filters through a Rule Engine (debounce + throttle + glob), and emits Agent Task triggers to downstream daemons, with permission audit (`fusion-guard`) and historical context (`fusion-memory`) on the path.

- **Language**: Swift 6, strict concurrency (`StrictConcurrency` experimental feature), `actor`-isolated throughout.
- **System API bindings**: `FSEvents` (file changes) + `NSWorkspaceNotificationCenter` (process launch/terminate, sleep/wake) + `NWPathMonitor` (network) + `Pasteboard` (clipboard) + `EndpointSecurity` (privileged process events — disabled by default, needs entitlement).
- **Event bus**: `AsyncStream` pub/sub (bounded 8192, backpressure) — NOT Tokio (the PRD said "Tokio Async Stream" but the Swift intent is Swift Concurrency / `AsyncStream`).
- **Protocol**: JSON-RPC 2.0 over Unix Domain Socket, NDJSON-framed (one message per `\n`).
- **Storage**: SQLite (WAL) for rules + debounce state; rolling JSONL event log.
- **Local-only**: every socket is UDS on the loopback; no cross-node TCP. `nodeId` carried in every event/signal/log line.

## Business Boundary

**In-scope**: macOS system-level file/process/clipboard/network listening; debounce/throttle + Rule Engine filtering; normalize system event → Agent Task trigger signal; trigger-chain contract ownership.

**Out-of-scope** (do not build here):
- Agent DAG workflow orchestration → `fusion-agent-studio`
- Embodied action execution → `fusion-executor`
- Memory storage / cognitive graph → `fusion-memory`
- Permission policy / DLP rules → `fusion-guard`

## Integration chains (all E2E-verified as of rc.4)

`fusion-event` owns the trigger-chain contract (D-10). Four integration points:

1. **`guard.audit`** → fusion-guard (direction A — upstream implemented the frozen contract). Sends trigger_id/event_type/target_path/target_agent/payload/node_id/tenant_id. **tenant_id MUST be `"default"`** (guard binds uid to `fg_store::DEFAULT_TENANT` only; other value → -32001 cross-tenant denied → fail-closed).
2. **`memory.retrieve_context`** → fusion-memory (direction B). Socket `~/.fusion-memory/fusion-memory.sock`. Bounded LRU cache, stale-cache/empty degrade on timeout.
3. **`task.submit`** → fusion-agent-studio (direction B). `input.event` in **snake_case** (matches `trigger_input.py` frozen contract). No retry on failure.
4. **`event.subscribe` / `event.notification`** push → consumers e.g. fusion-studio (direction B downstream — consumer adapts to fusion-event's frozen server contract). Push starts on connection accept, NOT on the subscribe line (subscribe RPC is just an ACK).

See `docs/integration.md` for the frozen contracts, `docs/api.md` for the full RPC reference.

## Build / Test / Lint

```bash
swift build                   # debug
swift build -c release        # release (what start.sh runs)
swift test                    # unit tests (71 passing, 10 skipped)
swift test --filter GlobTests # single suite
swift-format lint --recursive .   # swift-format 603.0.0, .swift-format config
```

Env-gated suites (skipped by default):
```bash
FUSION_EVENT_STRESS=1 swift test --filter StressHarnessTests        # chaos/long-run
FUSION_EVENT_E2E=1 swift test --filter E2EGuardTests                # real fusion-guard
FUSION_EVENT_E2E=1 swift test --filter E2EMemoryTests               # real fusion-memory
FUSION_EVENT_E2E=1 swift test --filter E2EStudioTests               # real agent-studio
FUSION_EVENT_E2E=1 swift test --filter E2ESubscribePushTests        # in-process #346 push
```

**Prereqs**: macOS 14+ (Apple Silicon), Xcode CLI tools, Swift 6 toolchain. Package links `EndpointSecurity` + `bsm` system libraries.

## Daemon lifecycle

`start.sh` (monorepo convention): `start | stop | status | log | doctor | install | uninstall`. Single-instance lock is `mkdir`-based (NOT `flock` — flock is absent on stock macOS; issue #8). Resident mode via launchd agent (`~/Library/LaunchAgents/com.fusion.event.plist`, KeepAlive). Runtime data in `~/.fusion-event/`.

## Conventions

- **IPC**: JSON-RPC 2.0 over UDS, socket 0600 + peer-uid auth, NDJSON-framed, batch requests supported.
- **Logging**: `os.Logger` (subsystem `com.fusion.event`) — always log, for problem localization.
- **Code style**: 4-space-multiple indentation, no docstrings, clean code only.
- **Concurrency**: `actor`-isolated types; no raw global mutable state.
- **Integration contracts**: freeze the RPC shape (params/return/degrade) in `docs/integration.md` before coding either side; mock and real servers share the contract (no mock-specific shapes).
- **Upstream changes**: for guard/memory/agent-studio contract changes — file an issue upstream first, then align here once frozen.

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

Full docs index in `README.md` → Documentation section.

## Key constraints

- **EndpointSecurity** privileged source: disabled by default (`esEnabled=false`). Needs `com.apple.developer.endpoint-security.client` entitlement (Apple application pending, issue #1). Degrades fail-closed to `NSWorkspace` (lower-fidelity process events). Phase-2 plan: separate System Extension process + XPC relay (L1 skeleton done, blocked on entitlement at L2/L3).
- **Release signing**: codesign + notarize not yet run — Developer ID credentials pending. See `docs/release-signing-checklist.md`.
- **Single-node**: no HA / leader election.