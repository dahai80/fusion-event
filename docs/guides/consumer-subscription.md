---
doc_id: fusion-event/consumer-subscription
product: fusion-event
class: platform
entry: service
doc_type: guide
title: {zh: "消费 fusion-event 事件流", en: "Consuming the fusion-event Event Stream"}
audience: engineer
status: draft
version: 0.1.0-rc.7
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - docs/api-reference.md
  - docs/integration.md
---

# 消费 fusion-event 事件流 / Consuming the fusion-event Event Stream

Two ways to consume fusion-event, per the frozen contracts in [integration.md](../integration.md): receive finished `task.submit` handoffs (downstream daemons like agent-studio), or subscribe to the raw NDJSON push stream (dashboard-style consumers like fusion-studio). This guide covers the subscription path end to end.

## What a subscriber no longer builds / 订阅方不再自建

A subscriber stops writing its own FSEvents/NSWorkspace listeners, event normalization, dedup, and heartbeat supervision — fusion-event delivers normalized raw events over one socket. Constraint: the stream is pre-rule (raw events); if you need rule-filtered triggers, use `rule.*` + `task.submit` semantics instead, or match locally against a copy of the rules.

## Connect and subscribe / 连接与订阅

```python
import socket, json

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
s.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": "event.subscribe"}) + "\n").encode())
```

The daemon acknowledges `{"subscribed": true}` and then pushes one NDJSON line per raw event:

```json
{"jsonrpc":"2.0","method":"event.notification","params":{"event":{...},"source":"fileModified"}}
```

## Heartbeat obligation / 心跳义务

The server pushes `event.heartbeat` every `heartbeatIntervalSec` (default 15s). The client MUST reply:

```python
if msg.get("method") == "event.heartbeat":
    s.sendall(b'{"jsonrpc":"2.0","method":"event.pong"}\n')
```

A client that stays silent is reaped after `heartbeat_dead_sec` (default 45s). This is the only client-side obligation; everything else (dedup, ordering, replay) is server-side.

## Testing rules without side effects / 干跑

Before wiring a consumer, validate rule behavior with `event.dry_run` (physically isolated from the Dispatcher — nothing fires downstream):

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"event.dry_run","params":{"limit":50}}' | nc -U /tmp/fusion-event.sock
```

Each returned event carries `matched_rules` and `would_trigger`.

## Historical inspection / 历史检查

Missed an event while disconnected? `event.replay` (`since_ts`, `limit`) reads the rolling JSONL `events.log`. The log rolls, so use replay for recent gaps, not archival queries.

## Failure posture / 失败姿态

- Socket missing → daemon down: `./start.sh start && ./start.sh doctor`.
- Reconnect with backoff, then `event.replay` to fill the gap since the last seen timestamp.
- The trigger path (guard audit, memory context, studio handoff) is daemon-side; a subscriber's failure never blocks triggering for other consumers.
