# fusion-event — Developer Guide

Build, test, lint, contribute, and extend the daemon.

## Prerequisites

- macOS 14.0+ (Apple Silicon), Xcode Command Line Tools, Swift 6.0 toolchain.
- For E2E tests against real upstream daemons: `fusion-guard`, `fusion-memory` (+ `fusion-mlx` embedding backend), `fusion-agent-studio` running. See [Integration guide](integration.md).

## Build

```bash
swift build                   # debug
swift build -c release        # release (what start.sh runs)
swift package generate-xcodeproj   # Xcode project if needed
```

The package links `EndpointSecurity` and `bsm` system libraries. Strict concurrency is enabled (`StrictConcurrency` experimental feature).

## Test

```bash
swift test                              # all unit tests
swift test --filter GlobTests           # single suite
swift test --filter GlobTests/testBasic # single test
```

Default `swift test` runs unit tests only — **71 passing, 10 skipped, 0 failures**. Skipped suites are env-gated:

```bash
# chaos/long-run stress harness (env-gated):
FUSION_EVENT_STRESS=1 FUSION_EVENT_STRESS_ITERS=5000 swift test --filter StressHarnessTests

# E2E integration against REAL upstream daemons (env-gated):
FUSION_EVENT_E2E=1 swift test --filter E2EStudioTests        # task.submit -> agent-studio
FUSION_EVENT_E2E=1 swift test --filter E2EMemoryTests        # retrieve_context -> fusion-memory
FUSION_EVENT_E2E=1 swift test --filter E2EGuardTests         # guard.audit -> fusion-guard
FUSION_EVENT_E2E=1 swift test --filter E2ESubscribePushTests # event.subscribe push (in-process server)
```

E2E tests prove the full chain against live daemons — they verify socket paths, RPC params, and response contracts end-to-end. See [Integration guide](integration.md) for the contracts.

## Lint

```bash
swift-format lint --recursive .     # swift-format 603.0.0, .swift-format config (lineLength 200, 4-space indent)
```

`lint` exits 0 on warnings (non-strict). Configuration in `.swift-format`.

## Project layout

See [Architecture](ARCHITECTURE.md) → Source layout. Sources are under `Sources/fusion-event/`; tests under `Tests/fusion-eventTests/`.

Code style: 4-space-multiple indentation, no docstrings, `os.Logger` for all daemon output, `actor`-isolated types for concurrency safety.

## Adding an event source

1. Implement the `EventSource` actor protocol (`sources/EventSource.swift`): `start()` registers with `EventBus`, `stop()` tears down.
2. Add a concrete source under `sources/` (e.g. `FSEventsSource.swift`).
3. Normalize to `RawEvent` (`sourceType`, `targetPath`, `payload`, `timestamp`) and publish via `bus.publish(event)`.
4. Register in `main.swift` via `SourceRegistry`.
5. Add tests; mirror the existing source test style.

## Adding a downstream bridge

1. **Freeze the RPC contract first** (params / return / degrade policy) in [Integration guide](integration.md) before coding either side.
2. Implement a bridge actor modeled on `AuditBridge` / `ContextBridge` (`bridges/`): call via `UDSClient` + `withTimeout`, handle `connectionFailed` / `timeout` / `ioError`, define fail-open vs fail-closed.
3. Wire into `Dispatcher`'s fan-out.
4. Add a mock-server contract test mirroring the frozen contract (no mock-specific shapes — mock and real share the contract).

## Contributing

- Fork → branch → PR against `main`. Squash or merge commits both accepted.
- Keep PRs surgical: touch only what the change requires (see the monorepo "surgical changes" convention).
- New code: include logging (`os.Logger`), 4-space indentation, no docstrings.
- Tests are not optional but they're not the goal — write meaningful tests, not ones that pass for the wrong reason.
- For upstream contract changes (guard/memory/agent-studio shapes): file an issue upstream first, then align here once the contract is frozen. See the [Integration guide](integration.md) for current frozen contracts.
