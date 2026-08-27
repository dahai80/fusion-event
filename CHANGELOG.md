# Changelog

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
