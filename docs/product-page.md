---
doc_id: fusion-event/product-page
product: fusion-event
class: platform
entry: service
doc_type: product-page
title: {zh: "fusion-event 产品页", en: "fusion-event Product Page"}
audience: engineer
status: draft
version: 0.1.0-rc.7
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - README.md
  - CLAUDE.md
  - docs/ARCHITECTURE.md
---

# fusion-event 产品页 / Product Page

| | |
|---|---|
| Product | fusion-event |
| Class | platform |
| Entry | service (macOS daemon, UDS JSON-RPC) |
| Version | 0.1.0-rc.7 |
| Language | Swift 6 (strict concurrency, actor-isolated) |

## What it is / 它是什么

fusion-event is the Fusion ecosystem's perception layer: a macOS-native reactive event daemon. It listens to system-level events (file / process / clipboard / network), normalizes them, filters them through a Rule Engine (debounce + throttle + glob), and emits Agent Task triggers to downstream daemons — with a permission audit (`fusion-guard`) and historical context (`fusion-memory`) on the trigger path.

fusion-event 是 Fusion 生态的感知层：macOS 原生响应式事件 daemon。监听系统级事件（文件/进程/剪贴板/网络），归一化后经规则引擎（防抖 + 节流 + glob）过滤，向下游 daemon 发出 Agent Task 触发——触发路径上串联 fusion-guard 权限审计与 fusion-memory 历史上下文。

It turns the agent model from "wait for a user prompt" into "sense a system event → trigger the Agent Swarm".

## What consumers no longer have to do / 消费方不再需要做什么

- **No per-app FSEvents/NSWorkspace plumbing.** Downstream daemons stop writing their own event listeners, normalizers, and debounce logic — they either receive `task.submit` handoffs (agent-studio) or subscribe to the NDJSON push stream (`event.subscribe` / `event.notification`). Constraint: subscription delivers raw pre-rule events; rule evaluation stays server-side.
- **No own trigger throttling.** The Rule Engine's debounce + throttle + glob filtering and the Dispatcher's token bucket (max concurrent trigger chains, default 5) are shared infrastructure. Consumers no longer reimplement burst protection. Constraint: `tokenBucketMax` bounds global concurrency, not per-consumer.
- **No bespoke audit/context wiring.** Every trigger passes the frozen `guard.audit` gate (pass/block/challenge, fail-closed when `require_guard=true`) and pulls historical context via `memory.retrieve_context` before handoff. Consumers no longer wire guard/memory themselves. Constraint: guard tenant is fixed to `default`.
- **No crash-unsafe trigger queues.** The Dispatcher uses a crash-safe outbox — downstream outages cause backlog, not loss; the outbox replays on restart. Consumers no longer build their own retry stores. Constraint: replay ordering is per-outbox, not transactional with the source event.
- **No duplicate idempotency logic.** Trigger signals carry an idempotency key (`SHA256(nodeId|rule|type|path|bucket)`); duplicate suppression is built in.

## Key capabilities / 核心能力

| Capability | Surface | Consumer benefit | Constraint |
|---|---|---|---|
| System event sources | file (FSEvents) / process / clipboard / network | One daemon normalizes all sources | EndpointSecurity source needs an Apple entitlement (pending) — degrades to NSWorkspace fidelity |
| Rule Engine | `rule.add/remove/list/reload` | Runtime rule management, SQLite WAL persistence | Rules validated server-side (`-32001` on invalid) |
| Dry-run | `event.dry_run` | Test-match rules without triggering downstream | Read-only, physically isolated from the Dispatcher |
| Replay | `event.replay` | Read-only replay of the rolling JSONL event log | Log is local, single-node |
| Push subscription | `event.subscribe` / `event.notification` | NDJSON server-push stream (e.g. fusion-studio) | Clients must answer `event.pong` or get reaped after `heartbeat_dead_sec` |
| Guard audit gate | outbound `guard.audit` | Permission audit on every trigger | 2s timeout; fail-closed when required |
| Context bridge | outbound `memory.retrieve_context` | Historical context on the trigger path | 3s timeout, 60s cache TTL |
| Studio handoff | outbound `task.submit` | Frozen snake_case `input.event` contract to agent-studio | 5s timeout, `max_retries` default 2 |

## Interfaces / 接入方式

- **UDS JSON-RPC 2.0, NDJSON-framed**: default socket `/tmp/fusion-event.sock` (override `FUSION_EVENT_SOCK`). Full method reference: [api-reference.md](api-reference.md); frozen downstream contracts: [integration.md](integration.md).
- **Lifecycle**: `./start.sh start|stop|status|log|doctor|install|uninstall` (ad-hoc or launchd resident mode). UDS-only — the daemon owns no TCP port.

## What it is not / 边界

- Not a workflow engine: it emits triggers; orchestration lives in agent-studio / cowork.
- Not a security policy owner: it consults fusion-guard; policy stays in guard.
- Single-node only (no HA / leader election).

## Status / 状态

`0.1.0-rc.7` (2026-10-30). All four integration chains E2E-verified against live upstream daemons; 71 unit tests passing. Known limitations: ES privileged source disabled by default (entitlement pending), release signing not yet run, single-node. History in [CHANGELOG.md](../CHANGELOG.md).
