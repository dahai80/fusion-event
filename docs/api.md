# fusion-event — API Reference

JSON-RPC 2.0 over Unix Domain Socket (UDS), NDJSON-framed (one message per `\n`).
Default socket: `/tmp/fusion-event.sock`.

## Wire format

Every line is a JSON-RPC 2.0 message. Requests carry `id`; the server replies with
a `result` or `error` object on its own line. Notifications (`event.notification`,
`event.heartbeat`) are server-pushed, no reply.

```json
{"jsonrpc":"2.0","id":1,"method":"event.health"}
```

Reply:
```json
{"jsonrpc":"2.0","id":1,"result":{"ok":true,"version":"0.1.0","uptime_sec":12,"sources":{...},"triggers":{...},"sock":"/tmp/fusion-event.sock","node_id":"macbook"}}
```

## Methods

### `ping`
No params. Returns `{"pong": true}`. Liveness check.

### `event.health`
No params. Returns daemon health.
```json
{
  "ok": true,
  "version": "0.1.0",
  "schema_version": 1,
  "uptime_sec": 120,
  "sources": {
    "fileModified": {"enabled": true, "events_total": 42, "errors": 0},
    "processTerminated": {"enabled": true, "events_total": 7, "errors": 0},
    "clipboardChanged": {"enabled": true, "events_total": 3, "errors": 0},
    "networkStatusChanged": {"enabled": true, "events_total": 1, "errors": 0}
  },
  "triggers": {"submitted": 5, "blocked": 1, "failed": 0},
  "sock": "/tmp/fusion-event.sock",
  "node_id": "macbook"
}
```

### `event.shutdown`
No params. Initiates graceful stop. Returns `{"ok": true}` then the daemon closes.

### `rule.add`
Add or replace a rule (upsert by `rule_name`).
Params:
| field | type | required | default | notes |
|-------|------|----------|---------|-------|
| `rule_name` | string | yes | — | unique key |
| `event_type` | string | yes | — | `fileModified` / `processTerminated` / `clipboardChanged` / `networkStatusChanged` |
| `target_agent` | string | yes | — | e.g. `fusion-code` |
| `path_pattern` | string | no | match-all | glob, see Glob spec |
| `debounce_ms` | int | no | 0 | drop repeats within window |
| `throttle_ms` | int | no | 0 | at most one fire per window |
| `enabled` | bool | no | true | |
| `max_retries` | int | no | 2 | |
| `require_guard` | bool | no | false | fail-closed if guard down |
| `target_graph_id` | string | no | "" | agent-studio graph |

Returns `{"ok": true, "rule_name": "..."}`.

### `rule.remove`
Params `{"rule_name": "..."}`. Returns `{"ok": true}`.

### `rule.list`
No params. Returns `{"rules": "<JSON string of [EventRule]>"}`.
The `rules` value is a JSON-encoded string (re-encode to get the array).

### `rule.reload`
No params. Reloads rules + debounce state from SQLite. Returns `{"ok": true, "count": N}`.

### `event.replay`
Params `{"since_ts"?: int, "limit"?: int}` (defaults 0, 100). Read-only replay of the
rolling JSONL event log. Returns `{"events": "<JSON string of [LoggedEvent]>"}`.

### `event.dry_run`
Params `{"since_ts"?: int, "limit"?: int}`. Replay against current rules WITHOUT
triggering downstream — physically isolated from Dispatcher (R4). Returns
`{"events": "[{event, matched_rules, would_trigger}]"}`.

### `event.subscribe`
No params. Acknowledges `{"subscribed": true}`, then the server pushes
`event.notification` lines for every raw event (pre-rule):
```json
{"jsonrpc":"2.0","method":"event.notification","params":{"event":{...},"source":"fileModified"}}
```

### `event.pong`
Heartbeat reply. No response. The server sends `event.heartbeat` periodically;
clients should reply `event.pong` to avoid being reaped after `heartbeat_dead_sec`.

## Error codes
| code | meaning |
|------|---------|
| -32700 | parse error |
| -32601 | method not found |
| -32001 | rule validation |
| -32603 | internal error |

## Minimal Python client
```python
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
s.sendall((json.dumps({"jsonrpc":"2.0","id":1,"method":"event.health"}) + "\n").encode())
s.settimeout(3); buf = b""
while b"\n" not in buf: buf += s.recv(4096)
print(json.loads(buf.decode())["result"])
```
