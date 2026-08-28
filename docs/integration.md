# fusion-event — Integration Guide

How downstream Fusion daemons consume `fusion-event`. This is the ecosystem contract
frozen at M0 (PRD plan §6.7); mock servers and real servers share the same contract.

## Topology

```
system event ─► fusion-event ─► fusion-guard   (guard.audit, audit gate)
                              ─► fusion-memory  (memory.retrieve_context, context pull)
                              ─► fusion-agent-studio (task.submit, trigger handoff)
```

`fusion-event` owns the trigger-chain contract (D-10). It defines the RPC shapes
below; downstream daemons conform. The contract is frozen so mock→real switch is
zero-rework (H3).

## Outbound: what fusion-event calls

All outbound are JSON-RPC 2.0 over UDS, NDJSON-framed, same as the inbound IPC.

### 1. `guard.audit` → fusion-guard
Socket: `guardSock` (default `/tmp/fusion-guard.sock`). Timeout 2s (H4).
```json
{"jsonrpc":"2.0","id":N,"method":"guard.audit","params":{
  "trigger_id":"<uuid>",
  "event_type":"fileModified",
  "target_path":"/Users/you/src/a.swift",
  "target_agent":"fusion-code",
  "payload":{"key":"value"},
  "node_id":"macbook"
}}
```
Expected reply:
```json
{"jsonrpc":"2.0","id":N,"result":{
  "decision":"pass|block|challenge",
  "reason":"...",
  "risk_level":0,
  "audit_id":"<id>"
}}
```
Degrade (H4): on connection-failed / timeout / io-error:
- `require_guard=false` → `degradedFailOpen` (proceed, audit-logged).
- `require_guard=true`  → `failClosed` (block trigger).

### 2. `memory.retrieve_context` → fusion-memory
Socket: `memorySock` (default `/tmp/fusion-memory.sock`). Timeout 3s (H4).
Bucketed TTL cache (default 60s); on miss/timeout falls back to stale cache or empty.
```json
{"jsonrpc":"2.0","id":N,"method":"memory.retrieve_context","params":{
  "trigger_id":"<uuid>",
  "query":"/Users/you/src/a.swift|fileModified",
  "top_k":5,
  "node_id":"macbook"
}}
```
Expected reply:
```json
{"jsonrpc":"2.0","id":N,"result":{
  "context":"<string>",
  "memory_ids":["id1","id2"],
  "cache_hit":false
}}
```

### 3. `task.submit` → fusion-agent-studio
Socket: `studioSock` (default `/tmp/fusion-studio.sock`). Timeout 5s.
Token bucket (max concurrent chains = `tokenBucketMax`, default 5); excess queues,
queue > 50 drops oldest (R1). No retry on failure (R3).
```json
{"jsonrpc":"2.0","id":N,"method":"task.submit","params":{
  "title":"event:<rule_name>",
  "description":"fileModified @ /Users/you/src/a.swift",
  "agent_id":"fusion-code",
  "graph_id":"",
  "input":"<JSON string: {trigger_id,event,context,rule_name,node_id}>",
  "trigger":"immediate",
  "priority":0,
  "idempotency_key":"<sha256 rule|type|path|bucket>"
}}
```
Expected reply:
```json
{"jsonrpc":"2.0","id":N,"result":{"task":{"task_id":"<id>"}}}
```
The `idempotency_key` (D-9) lets agent-studio dedup; fusion-event also keeps a local
LRU as a fallback. **Upstream issue:** agent-studio `task.submit` should reject
duplicate `idempotency_key` submissions (M0 issue to agent-studio).

## Idempotency key

`SHA256(rule_name | event_type | target_path | bucket)` where
`bucket = timestamp_ms / max(debounce_ms, 1)`. Same rule+event within one debounce
window → same key → one task (H1). Across buckets → different keys.

## Node boundary (H2, D-8)

Each node runs its own `fusion-event`. The trigger chain is **local-only**:
`fusion-event` never opens a cross-node TCP socket. If `fusion-agent-studio` schedules
the task across nodes via `fusion-multi-node`, `fusion-event` is not involved — its
`node_id` is carried in every event/signal/log line for traceability. UDS does not
upgrade to TCP.

## Heartbeat (E6)

Server pushes `event.heartbeat` every `heartbeat_interval_sec` (default 15). Clients
reply `event.pong`. Connections silent longer than `heartbeat_dead_sec` (default 45)
are reaped.

## Adding a new downstream consumer

1. Freeze the RPC contract here (params/return/degrade) before coding either side.
2. `fusion-event` calls it via `UDSClient` + `withTimeout` (see AuditBridge/ContextBridge).
3. Degrade policy: define fail-open vs fail-closed and the timeout.
4. Mock server in tests must use the **same** contract (no mock-specific shapes).
