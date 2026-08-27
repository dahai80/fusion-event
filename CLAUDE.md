# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

Greenfield — no source yet, no git repo, no `Package.swift`. The intended design lives in the parent monorepo: `../architecture/fusion-event-prd-0826.md` (authoritative) and `../architecture/fusion-union-architecture.md` (ecosystem flow). This file captures that intent so the first implementation lands coherently.

## What fusion-event Is

A macOS-native **reactive event daemon** — the ecosystem's perception layer. It turns passive "wait for User Prompt" into "sense system events → trigger Agent Swarm". Sits in the `macOS/Git` perception row of the union architecture alongside `fusion-guard`, `fusion-memory`, `fusion-executor`.

- **Language**: Swift 6 (direct access to macOS C/Obj-C system APIs).
- **System API bindings**: `FSEvents` (file changes) + `NSWorkspaceNotificationCenter` (process launch/terminate, sleep/wake) + `EndpointSecurity` (privileged process/network events).
- **Event bus**: Unix Domain Socket (UDS) pub/sub with Swift async streams. (PRD phrases the async layer as "Tokio Async Stream" — Tokio is Rust; the Swift intent is Swift Concurrency / `AsyncStream`.)
- **Protocol**: JSON-RPC 2.0 over UDS — matches the monorepo-wide IPC convention used by `fusion-studio` ↔ Python services.

### Captured event sources
File modifications, process termination, clipboard changes, network status changes, system notifications. Each is normalized to a `SystemEvent` then filtered through debounce/throttle + a Rule Engine into an Agent Task trigger signal.

### Core types (from PRD, baseline contract)
```swift
public enum SystemEventType: String, Codable {
    case fileModified
    case processTerminated
    case clipboardChanged
    case networkStatusChanged
}

public struct SystemEvent: Codable {
    public let eventId: String
    public let type: SystemEventType
    public let targetPath: String?
    public let timestamp: UInt64
    public let payload: [String: String]
}
```

Subscribe API is `Event.Subscribe` over JSON-RPC 2.0/UDS, binding a `rule_name` + `event_type` + `path_pattern` + `debounce_ms` to a `target_agent` (e.g. `fusion-code`).

## Business Boundary

**In-scope**: macOS system-level file/process/clipboard/network/notification listening; debounce/throttle + Rule Engine filtering; normalize system Event → Agent Task trigger signal.

**Out-of-scope** (do not build here):
- Agent DAG workflow orchestration → `fusion-agent-studio`
- Embodied action execution → `fusion-executor`

## Ecosystem Flow

Per union architecture, the event path is:
```
FSEvents ──► fusion-event ──► fusion-guard (TCC/DLP permission + injection-risk audit)
                                └─► fusion-event triggers Task + pulls history context ──► fusion-memory
```
- `fusion-guard`: validates permissions / injection risk before an event fires.
- `fusion-memory`: supplies historical/cognitive context for the triggered Task.
- `fusion-executor`: downstream actor once a Task is decided.
- `fusion-agent-studio`: owns the multi-step DAG the triggered Task may feed into.

## Build / Test / Lint (anticipated)

No `Package.swift` exists yet. Once bootstrapped as a Swift Package, follow the monorepo Swift conventions (see `../fusion-studio`):

```bash
swift build                       # debug
swift build -c release            # release
swift test                        # unit tests
swift package generate-xcodeproj  # Xcode project if needed
```

**Prereqs**: macOS (Apple Silicon), Xcode CLI tools, Swift 6 toolchain. `EndpointSecurity` requires a signed binary with the system Extension entitlement and runs in user space as a system extension — flag this early when wiring privileged event sources.

For the daemon lifecycle, follow the monorepo `start.sh` pattern used by `fusion-agent-studio`, `fusion-code`, `fusion-kb`, `fusion-multi-node`, `fusion-projects`: a `start.sh` exposing `start | stop | status | log | doctor`.

## Conventions to Match

- **IPC**: JSON-RPC 2.0 over UDS (socket path convention — coordinate with `fusion-studio` Services).
- **Logging**: always log, for problem localization (monorepo-wide rule). Swift: use `os.Logger` (Apple unified logging) for system-level daemon output.
- **Code style**: 4-space-multiple indentation, no docstrings, clean code only.
- **Monorepo**: shares one `.venv/` at `../` (Python only — not used here) and a `.python-version` that does not apply to this Swift project. Only touch code in `fusion-event/`; upstream issues → issue first, then PR (monorepo flow).

## When Implementing

1. Read `../architecture/fusion-event-prd-0826.md` for the full contract before writing types.
2. Read `../architecture/fusion-union-architecture.md` for the cross-daemon flow before wiring IPC.
3. Bootstrap `Package.swift` first, then the `SystemEvent`/`SystemEventType` contract, then the UDS JSON-RPC server, then individual event sources (FSEvents → NSWorkspace → EndpointSecurity last, as it needs entitlements).
