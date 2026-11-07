---
doc_id: fusion-event/troubleshooting
product: fusion-event
class: platform
entry: service
doc_type: troubleshooting
title: {zh: "fusion-event 故障排查", en: "fusion-event Troubleshooting"}
audience: engineer
status: draft
version: 0.1.0-rc.7
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - docs/USAGE.md
  - start.sh
  - docs/integration.md
---

# fusion-event 故障排查 / Troubleshooting

## Daemon lifecycle

**"another start.sh instance holding lock"** — a prior instance crashed without releasing the single-instance lock, or one is actually running. Check `./start.sh status`; if stale, remove `~/.fusion-event/.lock` (mkdir-based lock, fails fast by design).

**`connect /tmp/fusion-event.sock` → no such file** — the daemon is not running. `./start.sh start`, then `./start.sh doctor` (checks socket, `event.health` RPC, trigger/outbox backlog, rules.db).

**`start` refuses to launch with a registry error** — a TCP `port:` entry for fusion-event appeared in `port-registry.yaml`; fusion-event is UDS-only and this is treated as misregistration (issue #14). Remove the `port:` entry. Standalone deploys without the fusion tree: the missing registry file only warns; `FUSION_SKIP_REGISTRY_CHECK=1` bypasses the refusal.

**Ad-hoc start broken on stock macOS** — fixed in 0.1.0-rc.7 (issue #14, port-registry self-check + repaired ad-hoc path). Update if on an older rc.

## Rules and triggers

**Triggers not firing** — two common causes: the rule `path_pattern` does not match (glob semantics in [glob-spec.md](glob-spec.md)), or `require_guard=true` and the guard daemon is down (fail-closed). Inspect with `rule.list`; test-match without triggering via `event.dry_run`.

**Rule add fails with `-32001`** — rule validation error; check required fields (`rule_name`, `event_type`, `path_pattern`) and types.

**Duplicate triggers for one event** — should not happen: TriggerSignals carry an idempotency key `SHA256(nodeId|rule|type|path|bucket)`. If seen, check whether two rules with different names match the same event — that is two distinct rules, not a dedup failure.

**Rules changed on disk but daemon behaves old** — rules are loaded from SQLite; call `rule.reload` (returns the rule count) or restart.

## Downstream chains

**`guard.audit` → -32001 cross-tenant denied** — fusion-event uses tenant `default`; a non-default tenant on the guard side denies it. Do not override the tenant.

**Outbox backlog growing** — downstream (agent-studio) is slow or down. `./start.sh doctor` shows the backlog. The crash-safe outbox replays on restart; fix the downstream and let it drain. `task.submit` timeout is 5s with `max_retries` default 2.

**No historical context in triggers** — `memory.retrieve_context` timed out (3s) or `~/.fusion-memory/fusion-memory.sock` is missing; check the fusion-memory daemon. Context cache TTL is 60s, so recovery is quick after the memory daemon returns.

## Subscriptions and events

**Subscriber connection reaped** — the server pushes `event.heartbeat` every 15s; a client that never replies `event.pong` is reaped after `heartbeat_dead_sec` (45s). Reply to heartbeats.

**Process events low-fidelity (no exec/fork detail)** — expected without the Apple `endpoint-security.client` entitlement: the ES source is disabled by default and `NSWorkspace` provides the degrade. Enable ES only with the entitlement (`FUSION_EVENT_ES_ENABLED=1`).

**Want to see what would fire without side effects** — `event.dry_run` replays recent events against current rules with the path physically isolated from the Dispatcher.

**Replay window** — `event.replay` reads the rolling JSONL `events.log` (`since_ts`, `limit` defaults 0/100); the log rolls, so very old events are gone by design.

## Diagnostics checklist

```bash
./start.sh status         # pid, socket, rss
./start.sh doctor         # full health check
./start.sh log -f         # unified log (os.Logger, subsystem com.fusion.event)
ls -la ~/.fusion-event/   # config, rules.db, events.log, lock
echo '{"jsonrpc":"2.0","id":1,"method":"event.health"}' | nc -U /tmp/fusion-event.sock
```

`event.health` returns `ok`, version, uptime, per-source counters, trigger stats, and the socket path. In-process metrics (latency P50/P99, backpressure duration, drop counts) are available via the `event.metrics` RPC — see [api-reference.md](api-reference.md).

## Known limitations

- EndpointSecurity privileged source disabled by default (entitlement pending).
- Release signing (codesign + notarize) not yet run — see [release-signing-checklist.md](release-signing-checklist.md).
- Single-node only (no HA / leader election).
