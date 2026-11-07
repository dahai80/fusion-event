---
doc_id: fusion-event/get-started
product: fusion-event
class: platform
entry: service
doc_type: get-started
title: {zh: "fusion-event 快速开始", en: "fusion-event Get Started"}
audience: engineer
status: draft
version: 0.1.0-rc.7
updated: 2026-11-07
owner: "@dahai"
source_of_truth:
  - README.md
  - docs/USAGE.md
  - start.sh
---

# fusion-event 快速开始 / Get Started

Requirements: macOS 14.0+ (Apple Silicon), Swift 6 toolchain (Xcode CLI Tools).

## 1. Build / 构建

```bash
cd fusion-event
swift build -c release
```

## 2. Start the daemon / 启动

```bash
./start.sh start        # launch daemon (nohup + PID file)
./start.sh status       # pid, socket, rss
./start.sh doctor       # health check: socket / event.health RPC / backlog / rules.db
./start.sh log -f       # tail log
./start.sh stop         # graceful stop
```

For always-on production, prefer the launchd resident mode: `./start.sh install` (KeepAlive crash-restart) — use one mode, not both. Default socket: `/tmp/fusion-event.sock` (override `FUSION_EVENT_SOCK`). The daemon is UDS-only; `start` refuses to launch if a TCP `port:` entry for fusion-event ever appears in `port-registry.yaml` (misregistration guard).

## 3. First call / 首次调用

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"event.health"}' | nc -U /tmp/fusion-event.sock
```

Expected: a JSON-RPC reply with `"ok": true`, version, uptime, per-source counters, and `sock`.

## 4. Add a rule / 添加规则

```bash
echo '{"jsonrpc":"2.0","id":2,"method":"rule.add","params":{"rule_name":"watch-docs","event_type":"fileModified","path_pattern":"~/docs/**/*.md"}}' | nc -U /tmp/fusion-event.sock
```

Rules persist to SQLite (`~/.fusion-event/rules.db`, WAL). `rule.reload` re-reads them without restart. Glob semantics: [glob-spec.md](glob-spec.md).

## 5. Test without triggering / 干跑验证

```bash
echo '{"jsonrpc":"2.0","id":3,"method":"event.dry_run","params":{"limit":50}}' | nc -U /tmp/fusion-event.sock
```

Returns recent events with `matched_rules` and `would_trigger` — the dry-run path is physically isolated from the Dispatcher, so nothing fires downstream.

## 6. Subscribe to raw events / 订阅原始事件

```python
import socket, json

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/fusion-event.sock")
s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"event.subscribe"}\n')
s.sendall(b'{"jsonrpc":"2.0","method":"event.pong"}\n')  # heartbeat reply
for line in s.makefile("r"):
    msg = json.loads(line)
    if msg.get("method") == "event.notification":
        print(msg["params"]["source"], msg["params"]["event"])
```

Reply `event.pong` to the periodic `event.heartbeat`, or the server reaps the connection after `heartbeat_dead_sec` (default 45s).

## 7. Run the tests / 运行测试

```bash
swift test        # 71 unit tests
```

## Next steps / 下一步

- Full RPC reference: [api-reference.md](api-reference.md)
- Configuration keys and runtime data: [config-reference.md](config-reference.md)
- Downstream integration contracts: [integration.md](integration.md)
- Troubleshooting: [troubleshooting.md](troubleshooting.md)
- Customer-facing install/run guide: [USAGE.md](USAGE.md)
