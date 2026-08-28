# fusion-event — Usage Guide

Customer-facing guide: install, run, configure, and troubleshoot the daemon.

## Prerequisites

- macOS 14.0+ (Sonoma or later), Apple Silicon.
- Xcode Command Line Tools (`xcode-select --install`).
- Swift 6.0 toolchain.
- EndpointSecurity privileged source (optional) requires a signed binary with the `com.apple.developer.endpoint-security.client` entitlement — see [Release signing checklist](release-signing-checklist.md). Without it the daemon runs with the ES source disabled and falls back to `NSWorkspace` for process events.

## Install

Clone and build:

```bash
git clone https://github.com/dahai80/fusion-event.git
cd fusion-event
swift build -c release      # produces .build/release/fusion-event
```

The release binary is what `start.sh` runs by default. No package manager install yet — run from the clone.

## Daemon lifecycle

`start.sh` follows the monorepo lifecycle convention:

```bash
./start.sh start      # launch daemon (nohup, release binary or debug)
./start.sh stop       # graceful stop (launchd-aware if installed, else nohup)
./start.sh status     # pid, socket, rss (launchd-aware)
./start.sh log [-f]   # tail daemon log
./start.sh doctor     # health check: socket / event.health RPC / triggers+outbox backlog / rules.db
./start.sh install    # install as launchd agent (KeepAlive, RunAtLoad, crash-restart)
./start.sh uninstall  # remove launchd agent
```

Two run modes — use one, not both:

- **Ad-hoc** (`start`/`stop`): runs via `nohup` with a PID file. Good for development and testing.
- **Resident** (`install`/`uninstall`): manages a launchd agent at `~/Library/LaunchAgents/com.fusion.event.plist` with `KeepAlive=true` for automatic crash-restart. Use this for always-on production.

`stop` and `status` auto-detect a launchd-managed process. Single-instance locking is enforced (a `mkdir`-based lock — fails fast if another instance holds it).

## Configuration

Config lives in `~/.fusion-event/config.json` (created on first run with defaults). Edit it while the daemon is stopped, or via `rule.*` RPCs at runtime.

| Key | Default | Meaning |
|-----|---------|---------|
| `sockPath` | `/tmp/fusion-event.sock` | UDS server socket (env `FUSION_EVENT_SOCK`) |
| `fseventsRoot` | `$HOME` | FSEvents watch root |
| `esEnabled` | `false` | enable EndpointSecurity source (env `FUSION_EVENT_ES_ENABLED=1`) |
| `esXpcEnabled` | `false` | enable ES XPC server skeleton (env `FUSION_EVENT_ES_XPC_ENABLED=1`) |
| `nodeId` | hostname | Node identity carried in every emitted event |
| `studioSock` | `/tmp/fusion-studio.sock` | agent-studio UDS (task.submit) |
| `guardSock` | `/tmp/fusion-guard.sock` | fusion-guard UDS (guard.audit) |
| `memorySock` | `~/.fusion-memory/fusion-memory.sock` | fusion-memory UDS (memory.retrieve_context) |
| `outboundTimeoutGuard` | `2` | guard.audit timeout (sec) |
| `outboundTimeoutMemory` | `3` | retrieve_context timeout (sec) |
| `outboundTimeoutDispatch` | `5` | task.submit timeout (sec) |
| `tokenBucketMax` | `5` | max concurrent trigger chains |
| `heartbeatIntervalSec` | `15` | IPC heartbeat push interval |
| `heartbeatDeadSec` | `45` | dead-connection reap threshold |
| `contextCacheTtlSec` | `60` | context bridge cache TTL |

Runtime data lives in `~/.fusion-event/`: `config.json`, `rules.db` (SQLite WAL), `launchd.log`, `events.log` (rolling JSONL).

## Rules

Rules map system events to downstream Agent tasks. Add via the `rule.add` RPC over the UDS socket:

```bash
python3 - <<'PY'
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
req = {"jsonrpc":"2.0","id":1,"method":"rule.add","params":{
    "rule_name":"swift-watch",
    "event_type":"fileModified",
    "target_agent":"fusion-code",
    "path_pattern":"/Users/you/src/**/*.swift",
    "debounce_ms":300,
    "require_guard":True
}}
s.sendall((json.dumps(req)+"\n").encode())
s.settimeout(3); buf=b""
while b"\n" not in buf: buf+=s.recv(4096)
print(json.loads(buf.decode()))
PY
```

Rule fields:

| field | required | meaning |
|-------|----------|---------|
| `rule_name` | yes | unique key (1–256 chars) |
| `event_type` | yes | `fileModified` / `processTerminated` / `clipboardChanged` / `networkStatusChanged` |
| `target_agent` | yes | downstream agent, e.g. `fusion-code` |
| `path_pattern` | no | glob match (`*` segment, `**` across dirs, `?` one char); default match-all |
| `debounce_ms` | no | drop repeats within window (default 0) |
| `throttle_ms` | no | at most one fire per window (default 0) |
| `require_guard` | no | fail-closed if fusion-guard is down (default false) |

See [Glob spec](glob-spec.md) for path-pattern details, [API reference](api.md) for the full RPC set.

## Health + metrics

Liveness + health:

```bash
python3 - <<'PY'
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
s.sendall((json.dumps({"jsonrpc":"2.0","id":1,"method":"event.health"})+"\n").encode())
s.settimeout(3); buf=b""
while b"\n" not in buf: buf+=s.recv(4096)
print(json.dumps(json.loads(buf.decode())["result"], indent=2))
PY
```

`event.health` returns `ok`, `version`, `uptime_sec`, per-source `events_total`/`errors`, and trigger counters (`submitted`/`blocked`/`failed`). `./start.sh doctor` runs this and reports outbox backlog (warns above 50).

In-process metrics (latency P50/P99, backpressure duration, drop counts) are available via the `event.metrics` RPC — see [API reference](api.md).

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `start.sh start` → "another start.sh instance holding lock" | a prior instance crashed without releasing, or one is running | `./start.sh status`; if stale, remove `~/.fusion-event/.lock` |
| `connect /tmp/fusion-event.sock` → no such file | daemon not running | `./start.sh start` then `./start.sh doctor` |
| Process events low-fidelity (no exec/fork) | ES entitlement missing → ES disabled → `NSWorkspace` fallback | expected without entitlement; apply for `endpoint-security.client` |
| `guard.audit` → -32001 cross-tenant denied | `tenant_id` not `"default"` | fusion-event uses `default`; do not override |
| Triggers not firing | rule `path_pattern` doesn't match, or `require_guard=true` + guard down | `rule.list` to inspect; `event.dry_run` to test-match without triggering |
| Outbox backlog growing | downstream (agent-studio) slow or down | `./start.sh doctor` shows backlog; restart downstream; outbox replays on restart |

Logs: `./start.sh log -f` (unified logging via `os.Logger`, subsystem `com.fusion.event`). Log rotation: `launchd.log` rotates at >10MB, keeps 4 generations.
