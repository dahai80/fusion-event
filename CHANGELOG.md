# Changelog

## [Unreleased]

### Changed
- **Public release docs**: repository transitioned to public visibility. Added bilingual README (`README.md` English default + `README_CN.md` Chinese, cross-linked). Rewrote `README.md` from an internal milestone ledger into a public-facing quick-start + architecture + integration overview (detailed internals moved to `docs/`). Refreshed stale `CLAUDE.md` (was greenfield-era, contradicted rc.4) to the current implemented state with standalone (non-monorepo) context.
- **Added docs**: `docs/USAGE.md` (customer install/run/configure/troubleshoot), `docs/ARCHITECTURE.md` (system design), `docs/DEVELOPMENT.md` (build/test/lint/extend/contribute).
- **PII scrub**: replaced `/Users/dahai/` example paths with `/Users/you/` in tracked docs/tests (real macOS username) ahead of the public flip. Working-tree only — git history retains the originals (username already in the GitHub handle).

## [0.1.0-rc.4] — 2026-08-28

Patch release. Verifies the guard chain against a real fusion-guard daemon (issue #3 CLOSED upstream), fixes a tenant_id bug discovered by that E2E test, and verifies the subscribe/push contract against fusion-studio's consumer-side implementation (issue #346).

### Fixed
- **guard chain tenant_id** (`AuditBridge.audit`): rc.3 hardcoded `tenant_id="fusion-event"`, but fusion-guard binds the local-daemon identity (uid) to `fg_store::DEFAULT_TENANT = "default"` only — any other value yields `cross-tenant audit denied (P0-1)` → RPC error -32001 → AuditBridge fail-closed. Changed to `tenant_id="default"`. Block still surfaces via `result.decision="block"` (S0), not RPC error.
- **`start.sh` single-instance lock on stock macOS** (issue #8): rc.1–rc.3 used `flock -n`, which does not exist on stock macOS (util-linux only). `start.sh start` failed with `flock: command not found`, and `set -e` + `if ! flock -n 9` turned that into the misleading "another start.sh instance holding lock" error — daemon never started on a stock macOS machine. Replaced with a `mkdir`-based directory lock (POSIX-guaranteed atomic, no external binary) plus stale-pid recovery (`rm -rf` + reclaim if the holder died without releasing, handling `SIGKILL` crashes) and a `trap 'rmdir ...' EXIT` release. Same fail-fast-if-locked semantics.

### Added
- **`E2EGuardTests.swift`** — env-gated (`FUSION_EVENT_E2E=1`) real-daemon E2E against live fusion-guard (UDS `/tmp/fusion-guard.sock`). Verifies fusion-event's own `AuditBridge.audit` code path (params build + socket call + `AuditDecision` response parse) for a benign path (→ `pass`, non-empty `audit_id`) and a malicious path (`rm -rf /` injection → `block`, non-empty `audit_id`). No cleanup: guard appends audit-chain rows (immutable ledger). Passed against real fusion-guard v0.1.1.
- **`E2ESubscribePushTests.swift`** — env-gated (`FUSION_EVENT_E2E=1`) E2E for the fusion-studio consumer contract (issue #346). Starts a real `IPCServer` in-process on a temp socket, connects a raw NDJSON UDS client (the studio `EventBridge` consumer path), and verifies the frozen push contract: `event.subscribe`→`{subscribed:true}`, `event.notification` push with `params.event{eventId,type,targetPath,timestamp,payload,nodeId}` + `params.source` for each published event, and the keepalive lifecycle (`event.heartbeat` every 15s, `event.pong` reply keeps the long-connection alive). No external daemon needed (in-process server). Both tests passed.

### Verification
- `swift build` (debug + release): green
- `swift test`: 71 passing, 10 skipped, 0 failures
- `swift-format lint`: exit 0
- **guard.audit real-daemon E2E** (issue #3 CLOSED): `FUSION_EVENT_E2E=1 swift test --filter E2EGuardTests` — both pass/block tests green against live fusion-guard
- **event.subscribe push E2E** (issue #346 implemented studio-side): `FUSION_EVENT_E2E=1 swift test --filter E2ESubscribePushTests` — subscribe ACK + notification push fields + heartbeat/pong keepalive green against in-process server
- memory + task.submit chains unchanged from rc.3 (already verified correct against upstream source)

## [0.1.0-rc.3] — 2026-08-28

Patch release. Corrects the guard-chain contract direction misjudged in rc.2.

### Fixed
- **guard chain** (issue #3 CLOSED, fusion-guard v0.1.1): AuditBridge calls `guard.audit` (direction A — upstream implemented the fusion-event D-10 frozen contract). rc.2 wrongly switched to `guard.evaluate` (direction B) after misreading upstream; verified fusion-guard v0.1.1 source exposes both `guard.evaluate` (content-scan) AND `guard.audit` (event-gate, D-10 frozen contract `{decision, reason, risk_level:int, audit_id, trigger_id}`). Reverted to `guard.audit` with correct params (`trigger_id`/`event_type`/`target_path`/`target_agent`/`payload{}`/`node_id`/`tenant_id`) and `AuditDecision` response parse. Four contract tests rewritten to the `AuditDecision` shape: pass/block/challenge/unknown-fail-closed-to-block.

### Verification
- `swift build` (debug + release): green
- `swift test`: 67 passing, 6 skipped, 0 failures
- `swift-format lint`: exit 0
- memory + task.submit chains unchanged from rc.2 (already verified correct against upstream source)
- **memory.retrieve_context real-daemon E2E** (issue #4 CLOSED, fusion-memory): added `E2EMemoryTests.swift` — env-gated (`FUSION_EVENT_E2E=1`), seeds a test Interaction via `commit` to a real fusion-memory daemon (UDS), calls fusion-event's own `ContextBridge.retrieveContext`, asserts non-empty context contains committed marker + `interaction_id` present in `memory_ids` + `cache_hit=false`, then cleans up via `delete_scope` (confirm=true). Passed against real fusion-memory + fusion-mlx embedding backend.

## [0.1.0-rc.2] — 2026-08-28

Patch release. Upstream contract alignment so all three integration chains work end-to-end. Adds CI + lint gating.

### Fixed — upstream contract alignment
- **guard chain** (issue #3, fusion-guard): AuditBridge now calls `guard.evaluate` (was `guard.audit`, which does not exist upstream). Serializes event to JSON `content` string with `content_type: "json"`, maps upstream `SafetyAction` (Allow/Preview/Redact/Block) to internal `GuardDecision` (pass/challenge/block/block), parses `risk_level` (L-string → Int) and `action_id` (was `audit_id`). Four contract tests added (MockGuard UDS server). **Note: superseded by rc.3 — fusion-guard v0.1.1 does expose `guard.audit` (D-10 contract); rc.2 misread upstream.**
- **memory chain** (issue #4 CLOSED upstream, fusion-memory): ContextBridge socket default aligned to upstream `~/.fusion-memory/fusion-memory.sock` (was `/tmp/fusion-memory.sock`). `retrieve_context` method/params/response already matched upstream contract; added missing `close()` for clean lifecycle. Three contract tests added (MockMemory UDS server): response parse, LRU cache hit, degrade-on-absent.
- **task.submit chain** (issue #250, fusion-agent-studio): Dispatcher `eventDict` now serializes `input.event` in snake_case (`event_id`, `target_path`, `node_id`) to match upstream `trigger_input.py` frozen contract (was camelCase). Regression test added. IPCServer `event.notification` push keeps camelCase (PRD + studio #346 consumer contract).

### Added
- CI workflow (`.github/workflows/ci.yml`): macos-14, build debug+release, swift test + test-count verify, swift-format lint gate.
- `.swift-format` (swift-format 603.0.0 schema): lineLength 200, 4-space indent, rules matched to existing codebase convention.
- 8 new contract tests (AuditBridge ×4, ContextBridge ×3, Dispatcher snake_case ×1). Total 66 passing (5 skipped).

### Known limitations
- EndpointSecurity privileged source still disabled — ES entitlement pending Apple approval.
- No HA / leader election — single-node only.
- Codesign/notarize not yet run — release signing credentials pending.
- 213 swift-format advisory warnings remain (built-in formatter Indentation/AddLines/RemoveLine suggestions on pre-existing codebase style; non-toggleable, lint exits 0). Not introduced by this change.

### Audit history
- rc.2 audit: 3-chain contract alignment verified against upstream sources (guard.evaluate, retrieve_context, trigger_input.py). See docs/release-signing-checklist.md.

## [0.1.0-rc.1] — 2026-08-27

First release candidate. macOS-native reactive event daemon — ecosystem perception layer.

### Features
- Event sources: FSEvents (file), NSWorkspace (process launch/terminate, sleep/wake, mount), Network (status change), Pasteboard (clipboard), EndpointSecurity skeleton (disabled — ES entitlement pending Apple approval)
- Event bus: bounded AsyncStream (8192) ingest/dispatch decouple, backpressure HIGH/NORMAL signal回流
- Rule engine: glob path match (non-backtracking state machine), debounce + throttle (per-window N), monotonic dedup high-water
- Normalizer → Dispatcher: token bucket + crash-safe outbox (atomic+fsync) + replay, idempotency keys (nodeId-scoped, LRU 10000)
- Bridges: AuditBridge (→ fusion-guard), ContextBridge (→ fusion-memory, bounded LRU cache), Dispatcher (→ fusion-agent-studio task.submit)
- IPC: JSON-RPC 2.0 over UDS, peer-uid auth, NDJSON framing, batch + notification, event.subscribe/notification, event.metrics (P50/P99 latency, counters, backpressure duration)
- Daemon lifecycle: start.sh (start/stop/status/log/doctor/install), launchd agent (KeepAlive+RunAtLoad), graceful shutdown with hard timeout + outbox drain
- Release engineering: scripts/sign.sh (codesign + notarytool + stapler, hardened runtime), entitlements (ES commented pending approval)
- Observability: MetricsCollector actor + LatencyHistogram, event.metrics RPC, os.Logger unified logging

### Tests
- 58 unit tests passing (4 stress + 1 E2E skipped by default)
- Stress harness (FUSION_EVENT_STRESS): long-run memory drift, downstream-kill outbox replay, disk-full degrade, concurrent IPC load
- E2E (FUSION_EVENT_E2E): real agent-studio daemon task.submit contract verified

### Known limitations (rc.1)
- EndpointSecurity privileged source disabled — ES entitlement (com.apple.developer.endpoint-security.client) pending Apple approval. NSWorkspace provides low-fidelity process events as degrade.
- guard.audit chain unverified — fusion-guard has no `guard.audit` method (uses `guard.evaluate` with content-scan semantics). Issue #3 filed, awaiting upstream direction.
- memory.retrieve_context chain unverified — 4 drifts vs fusion-memory `retrieve` (method/params/response/socket path). Issue #4 filed, awaiting upstream direction.
- task.submit input event field-name drift (camelCase vs snake_case) — issue #250 filed. Task still created; trigger_input parse affected.
- No HA / leader election — single-node only (A1/A2-3 deferred).
- Codesign/notarize not yet run — release signing credentials pending (see docs/release-signing-checklist.md).

### Audit history
4 audit rounds (P0-P3 + release engineering + E2E), all code-fixable items landed. See docs/audit-fixes-0827.md.
