---
doc_id: fusion-event/config-reference
product: fusion-event
class: platform
entry: service
doc_type: config-reference
title: {zh: "fusion-event 配置参考", en: "fusion-event Configuration Reference"}
audience: engineer
status: draft
version: 0.1.0-rc.7
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - docs/USAGE.md
  - Sources/fusion-event/Config.swift
  - start.sh
---

# fusion-event 配置参考 / Configuration Reference

Config lives in `~/.fusion-event/config.json` (created on first run with defaults). Edit it while the daemon is stopped, or change rules at runtime via `rule.*` RPCs. Sources: `docs/USAGE.md`, `Sources/fusion-event/Config.swift`.

## config.json keys

| Key | Default | Meaning |
|-----|---------|---------|
| `sockPath` | `/tmp/fusion-event.sock` | UDS server socket (env `FUSION_EVENT_SOCK`); 0600 + peer-uid authenticated |
| `fseventsRoot` | `$HOME` | FSEvents watch root |
| `esEnabled` | `false` | EndpointSecurity source (env `FUSION_EVENT_ES_ENABLED=1`); needs the Apple `endpoint-security.client` entitlement — without it the NSWorkspace fallback provides lower-fidelity process events |
| `esXpcEnabled` | `false` | ES XPC server skeleton (env `FUSION_EVENT_ES_XPC_ENABLED=1`) |
| `nodeId` | hostname | Node identity carried in every emitted event |
| `studioSock` | `/tmp/fusion-studio.sock` | agent-studio UDS (`task.submit` handoff) |
| `guardSock` | `/tmp/fusion-guard.sock` | fusion-guard UDS (`guard.audit` gate) |
| `memorySock` | `~/.fusion-memory/fusion-memory.sock` | fusion-memory UDS (`memory.retrieve_context`) |
| `outboundTimeoutGuard` | `2` | guard.audit timeout (sec) |
| `outboundTimeoutMemory` | `3` | retrieve_context timeout (sec) |
| `outboundTimeoutDispatch` | `5` | task.submit timeout (sec) |
| `tokenBucketMax` | `5` | max concurrent trigger chains (Dispatcher token bucket) |
| `heartbeatIntervalSec` | `15` | IPC heartbeat push interval |
| `heartbeatDeadSec` | `45` | dead-connection reap threshold |
| `contextCacheTtlSec` | `60` | context bridge cache TTL |

## Environment variables (start.sh + Config.swift)

| Variable | Default | Meaning |
|---|---|---|
| `FUSION_EVENT_SOCK` | `/tmp/fusion-event.sock` | Socket path override |
| `FUSION_EVENT_DATA` | `~/.fusion-event` | Runtime data directory (PID file, launchd.log also follow it) |
| `FUSION_EVENT_ES_ENABLED` | `0` | `1` enables the EndpointSecurity source |
| `FUSION_EVENT_ES_XPC_ENABLE` / `FUSION_EVENT_ES_XPC_ENABLED` | `0` | Enables the ES XPC server skeleton |
| `FUSION_REGISTRY` | `~/fusion/architecture/port-registry.yaml` | Registry file for the start.sh self-check |
| `FUSION_SKIP_REGISTRY_CHECK` | unset | `1` bypasses the start.sh registry self-check (standalone deploys) |

## Runtime data layout / 数据布局

All under `~/.fusion-event/` (or `FUSION_EVENT_DATA`):

| Path | Contents |
|---|---|
| `config.json` | Daemon configuration |
| `rules.db` (+ WAL) | Rules + debounce state (SQLite WAL) |
| `events.log` | Rolling JSONL event log (`event.replay` reads it) |
| `launchd.log` | Daemon output; rotates at >10MB, keeps 4 generations |
| `fusion-event.pid` | PID file (ad-hoc mode) |
| `.lock` | Single-instance lock (mkdir-based) |

## Lifecycle (start.sh)

```bash
./start.sh start|stop|status|log [-f]|doctor|install|uninstall
```

Two run modes — use one, not both: **ad-hoc** (`start`/`stop`, nohup + PID file) for development; **resident** (`install`/`uninstall`, launchd agent `~/Library/LaunchAgents/com.fusion.event.plist` with KeepAlive) for always-on production. `stop`/`status` auto-detect a launchd-managed process. `start` performs the port-registry self-check: fusion-event is UDS-only and owns no TCP port, so the presence of a `port:` entry for fusion-event in the registry is a misregistration and start refuses; a missing registry file warns and continues.

## Logging

Unified logging via `os.Logger`, subsystem `com.fusion.event`. Tail with `./start.sh log -f`. `launchd.log` rotates at >10MB, keeping 4 generations.
