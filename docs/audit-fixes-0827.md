# fusion-event 审计修复落地记录 (2026-08-27)

对应审计报告: `../audit/fusion-event-audit-0827.md`（上游 monorepo 审计目录，本文件仅记录修复，不改动审计原文）。

## 修复总览

P0–P3 全部审计发现已定位修复，39 单元测试全绿，debug + release 构建通过。

## 致命缺陷 (Fatal — 发布阻断)

| ID | 问题 | 修复 | 验证 |
|----|------|------|------|
| F1 | UDS 世界可写 + 零认证 → 本地任意 Agent 任务触发 | socket `chmod 0o600`；`accept` 后 `getsockopt` 取 peer uid 校验同 uid | IPCServer.swift |
| F2 | EventBus 串行化全链路 → 吞吐瓶颈 + 背压造假 | ingest 与 dispatch 解耦：有界 `AsyncStream`(bufferingNewest 8192) + worker Task；DB 批写；背压 drop 计数 (`dispatchDroppedCount`) | RuleEngineTests/MultiNodeTests stress |
| F3 | FSEvents glob `**` 递归：死代码 + 指数回溯 DoS | glob 重写为非回溯状态机 + 步长上限 | GlobTests |
| F4 | EndpointSecurity `extract` NULL 解引用 → 特权路径崩溃 | `tok.data` guard + `withMemoryRebound` 安全绑定 | ESTests |
| F5 | 超时后连接状态中毒 → 后续全部 RPC 失败 | 超时/失败后 `resetClient()` 丢弃中毒连接 | DispatcherTests |
| F6 | IPCServer 双 close + fd 回收竞态 | fd ownership 明确，`isConnClosed(fd:)` 按迭代校验，pumpEvents 不跨隔离返回 non-Sendable | IPCServer.swift |
| F7 | 配置每次启动被覆盖 → 用户配置不持久 | `Config.load` 不再 writeDefault，持久化读写；删死代码 `writeDefault` | Config.swift |
| F8 | IPCServer 单字节 recv + 无消息上限 → OOM DoS | 行长上限 `maxLineBytes` 1MB，超限断连 | IPCServer.swift |
| F9 | 幂等键在失败/阻断路径泄漏 → 误抑制合法重触发 | 仅 `task.submit` 成功 + guard `block`/`failClosed` 占键；submit 失败不占键允许重试 | DispatcherTests testIdempotency (真实 mock studio) |

## 逻辑 Bug / 架构硬伤

| ID | 问题 | 修复 |
|----|------|------|
| L1 | 信号处理 data race + async-signal-unsafe | `DispatchSource.makeSignalSource` 转回队列；`LifecycleHandle` `@unchecked Sendable` + `os_unfair_lock` 单例 |
| L2 | Dispatcher 队列溢出丢错对象 + 无界幂等表 | 队列上限检查前置；`recentKeys` LRU 硬上限 10000；purge 惰性 |
| L3 | throttle 实为 debounce 复制品 | throttle 改为每窗口允 N 次 (`throttleMaxPerWindow`)；DDL 迁移 + RPC 读写 |
| L4 | NSWorkspace wake 事件伪装成 networkStatusChanged | 新增 `SystemEventType.wake`，sleep/wake 不再冒充 |
| L5 | RuleStore.remove 忽略 prepare 返回 + 手拼 SQL | 检查 prepare rc，参数化 `debounce_state` 删除，去 `escape()` |
| L6 | FSEvents `Unmanaged.passUnretained(self)` → 潜在 UAF | 改 `passRetained` + 存 `infoPtr`，`stop()` release |
| L7 | 优雅停机不排空 Dispatcher.pendingQueue | `Lifecycle` 持 dispatcher，`gracefulShutdown` 调 `drainForShutdown` 记录不提交 |
| L8 | IPCServer send 忽略返回值 → 大通知截断 | 写循环 `writeAll` + 截断计数日志 |

## 性能隐患

| ID | 问题 | 修复 |
|----|------|------|
| P1 | EventLog 每事件 open/close 文件 + 全量 stat | 常驻 `FileHandle` + `writtenBytes` 计数，轮转用计数 |
| P2 | EventLog.replay/recentDebounceWindow 全文件载入内存 | 流式分块读 replay；reverse tail 读 recentDebounceWindow |
| P3 | SourceRegistry.health() 每次拷贝全量字典 | 直接返回引用 / 减少拷贝 |

## 可维护性

| ID | 问题 | 修复 |
|----|------|------|
| M1 | `nonisolated(unsafe)` 滥用 | 改 `@unchecked Sendable` + lock |
| M2 | 死代码 | 删 `writeDefault` 等 |
| M3 | README H5 "无 drop" 假宣称 + mock 掩盖真实瓶颈 | README 改为背压 drop 计数语义；测试用真实 mock studio 验证 F9 |
| M4 | rule.add/remove 无审计日志 | 加 `os.Logger notice` 审计行 |
| M5 | start.sh 无单例锁 | `flock` guard + `setsid` |

## 测试修复

F2 异步 dispatch 重写后，原同步断言需 `await engine.flush()` 等待 drain；stats dict 增 `dropped` 键 (F2/M4) 使 count 3→4；新增 `MockStudio` 真实 UDS server 验证 F9 成功占键语义（替代旧 mock sink 假宣称）。

额外加固: `UDSClient` socket `SO_NOSIGPIPE`（per-fd，防御 peer 关闭写时 SIGPIPE）。

## 构建/测试

```
swift build            # debug ok
swift build -c release # release ok
swift test             # 39 tests, 0 failures, 1.7s
```
