# fusion-event

> **Languages**: [English](README.md) | [中文](README_CN.md)

# fusion-event

macOS-native **reactive event daemon** — the Fusion ecosystem's perception layer.

Turns passive "wait for User Prompt" into **"sense system events → trigger Agent Swarm"**.
Listens to macOS system-level events (file / process / clipboard / network), normalizes them,
filters through a Rule Engine (debounce + throttle + glob), and emits Agent Task triggers to
downstream daemons — with permission audit (`fusion-guard`) and historical context
(`fusion-memory`) on the path.

- **Language**: Swift 6, strict concurrency (`actor`-isolated throughout)
- **Platform**: macOS 14.0+ (Apple Silicon)
- **IPC**: JSON-RPC 2.0 over Unix Domain Socket, NDJSON-framed
- **Storage**: SQLite (WAL) rules + debounce state; rolling JSONL event log
- **Local-only**: every socket is UDS on the loopback; no cross-node TCP

## Quick start

```bash
git clone https://github.com/dahai80/fusion-event.git
cd fusion-event
swift build -c release
./start.sh start        # launch daemon
./start.sh doctor       # health check
./start.sh status       # pid, socket, rss
./start.sh stop         # graceful stop
```

Add a rule — trigger a `fusion-code` agent task whenever a Swift file changes:

```python
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
s.sendall((json.dumps({"jsonrpc":"2.0","id":1,"method":"rule.add","params":{
    "rule_name":"swift-watch",
    "event_type":"fileModified",
    "target_agent":"fusion-code",
    "path_pattern":"/Users/you/src/**/*.swift",
    "debounce_ms":300,
    "require_guard":True
}})+"\n").encode())
s.settimeout(3); buf=b""
while b"\n" not in buf: buf+=s.recv(4096)
print(json.loads(buf.decode()))
```

## Architecture

```
FSEvents / NSWorkspace / NWPathMonitor / Pasteboard
          │ RawEvent
          ▼
      EventBus  ──► backpressure (bounded AsyncStream 8192)
          ▼
      RuleEngine ── glob match + debounce + throttle
          │ TriggerSignal (idempotency key = SHA256(nodeId|rule|type|path|bucket))
          ▼
      Dispatcher ── token bucket + crash-safe outbox
       ┌──────────┼──────────┐
       ▼          ▼          ▼
   AuditBridge ContextBridge task.submit
   → guard      → memory     → agent-studio
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## Integration

`fusion-event` is the trigger-chain owner. Four integration contracts, all E2E-verified:

| Chain | Direction | Daemon | Contract |
|-------|-----------|--------|----------|
| `guard.audit` | outbound | fusion-guard | audit gate (pass/block/challenge) |
| `memory.retrieve_context` | outbound | fusion-memory | historical context pull |
| `task.submit` | outbound | fusion-agent-studio | trigger handoff (snake_case `input.event`) |
| `event.subscribe` / `event.notification` | inbound (server push) | consumers (e.g. fusion-studio) | NDJSON push stream |

See [docs/integration.md](docs/integration.md) for the frozen RPC contracts and [docs/api.md](docs/api.md) for the full inbound RPC reference.

## Documentation

| Doc | Audience | Content |
|-----|----------|---------|
| [docs/USAGE.md](docs/USAGE.md) | Customers | install, run, configure, troubleshoot |
| [docs/INTEGRATION guide](docs/integration.md) | Integrators | downstream daemon contracts |
| [docs/api.md](docs/api.md) | Integrators | full RPC API reference |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Developers | system design, pipeline, reliability |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Contributors | build, test, lint, extend |
| [docs/glob-spec.md](docs/glob-spec.md) | All | path-pattern glob rules |

## Status

**`0.1.0-rc.5`** — fifth release candidate. All four integration chains E2E-verified against live upstream daemons / in-process server. 71 unit tests passing, 0 failures.

Known limitations:
- **EndpointSecurity** privileged source disabled by default — needs Apple `endpoint-security.client` entitlement (pending). `NSWorkspace` provides lower-fidelity process events as degrade.
- **Release signing** (codesign + notarize) not yet run — Developer ID credentials pending. See [docs/release-signing-checklist.md](docs/release-signing-checklist.md).
- Single-node only (no HA / leader election).

See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
