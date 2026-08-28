> **语言**: [English](README.md) | [中文](README_CN.md)

# fusion-event

macOS 原生**反应式事件守护进程** —— Fusion 生态的感知层。

把被动的"等待用户指令"变成**"感知系统事件 → 触发 Agent 群"**。
监听 macOS 系统级事件(文件 / 进程 / 剪贴板 / 网络),归一化后经规则引擎(debounce + throttle + glob)
过滤,向下游客子守护发 Agent Task 触发信号 —— 路径上带权限审计(`fusion-guard`)与历史上下文
(`fusion-memory`)。

- **语言**: Swift 6,严格并发(全程 `actor` 隔离)
- **平台**: macOS 14.0+(Apple Silicon)
- **IPC**: JSON-RPC 2.0 over Unix Domain Socket,NDJSON 分帧
- **存储**: SQLite(WAL)规则 + debounce 状态;滚动 JSONL 事件日志
- **仅本地**: 所有 socket 均为回环 UDS,无跨节点 TCP

## 快速开始

```bash
git clone https://github.com/dahai80/fusion-event.git
cd fusion-event
swift build -c release
./start.sh start        # 启动守护
./start.sh doctor       # 健康检查
./start.sh status       # pid、socket、内存占用
./start.sh stop         # 优雅停止
```

添加规则 —— Swift 文件变化即触发 `fusion-code` agent 任务:

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

## 架构

```
FSEvents / NSWorkspace / NWPathMonitor / Pasteboard
          │ RawEvent
          ▼
      EventBus  ──► 背压(有界 AsyncStream 8192)
          ▼
      RuleEngine ── glob 匹配 + debounce + throttle
          │ TriggerSignal(幂等键 = SHA256(nodeId|rule|type|path|bucket))
          ▼
      Dispatcher ── 令牌桶 + 崩溃安全 outbox
       ┌──────────┼──────────┐
       ▼          ▼          ▼
   AuditBridge ContextBridge task.submit
   → guard      → memory     → agent-studio
```

完整设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 集成

`fusion-event` 是触发链契约的拥有方。四个集成契约,均已 E2E 验证:

| 链 | 方向 | 守护 | 契约 |
|----|------|------|------|
| `guard.audit` | 出站 | fusion-guard | 审计闸门(pass/block/challenge) |
| `memory.retrieve_context` | 出站 | fusion-memory | 历史上下文拉取 |
| `task.submit` | 出站 | fusion-agent-studio | 触发交接(snake_case `input.event`) |
| `event.subscribe` / `event.notification` | 入站(服务端推) | 消费方(如 fusion-studio) | NDJSON 推流 |

冻结的 RPC 契约见 [docs/integration.md](docs/integration.md),完整入站 RPC 参考见 [docs/api.md](docs/api.md)。

## 文档

| 文档 | 读者 | 内容 |
|------|------|------|
| [docs/USAGE.md](docs/USAGE.md) | 客户 | 安装、运行、配置、排障 |
| [docs/integration.md](docs/integration.md) | 集成方 | 下游守护契约 |
| [docs/api.md](docs/api.md) | 集成方 | 完整 RPC API 参考 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 开发者 | 系统设计、流水线、可靠性 |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 贡献者 | 构建、测试、lint、扩展 |
| [docs/glob-spec.md](docs/glob-spec.md) | 全部 | path-pattern glob 规则 |

## 状态

**`0.1.0-rc.4`** —— 第四个发布候选。四条集成链全部 E2E 验证(真实上游守护 / 进程内服务)。71 个单测通过,0 失败。

已知限制:
- **EndpointSecurity** 特权源默认禁用 —— 需 Apple `endpoint-security.client` entitlement(审批中)。`NSWorkspace` 作为降级提供较低保真度的进程事件。
- **发布签名**(codesign + notarize)尚未执行 —— Developer ID 凭据待备。见 [docs/release-signing-checklist.md](docs/release-signing-checklist.md)。
- 单节点(无 HA / 选主)。

发布历史见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

Apache License 2.0 —— 见 [LICENSE](LICENSE)。