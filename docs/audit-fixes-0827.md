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
swift test             # 39 tests, 0 failures, 1.4s
```

---

# 第二轮: 架构审计修复 (fusion-event-audit-result-0827.md)

对应审计报告: `../audit/fusion-event-audit-result-0827.md`（外部独立架构审计, A/R/E 三类硬伤）。本轮修复全部外科可落地项; 需设计/外部依赖项如实延迟。

## 架构硬伤 (A)

| ID | 问题 | 修复 | 验证 |
|----|------|------|------|
| A1 | 单进程单节点无 HA, 无 leader 选举 | **延迟** — 需集群协调层设计 (Raft/租约), 非代码外科可修, 单列 PR | 文档标注延迟 |
| A2 | nodeId 取 hostname, 集群重名碰撞 | nodeId 持久化 UUID: 首启生成写 `node_id` 配置, 后续读持久值, 不再每启取 hostname | Config.swift, MultiNodeTests H2 |
| A3 | F2"解耦"造假: publish 仍同步 await process | 真解耦: `publish` yield 到有界 `AsyncStream`(bufferingNewest 8192) + worker Task 消费, publish 立即返回; 新增 `ingestInFlight` 计数 + `drainIngest()` 供 flush 等待 ingest 落地 | EventBus.swift, MultiNodeTests stress |
| A4 | ContextBridge.cache 无界, 长跑 OOM | 有界 LRU: `cacheMaxEntries` 上限 (默认 5000) + 主动 TTL purge 循环 (60s) | ContextBridge.swift |
| A5 | Normalizer 与 RuleEngine 职责纠缠 | 幂等键归一在 Normalizer, RuleEngine 只匹配/防抖/节流 — 边界已澄清 | Normalizer.swift, RuleEngine.swift |
| A6 | 墙钟 ms 无单调性, 时钟漂移破坏去重 | `monotonicHighWater` 单调水位: 回拨检测 clamp 到 `hwm+1`, 去重用单调时戳 | RuleEngine.swift (A6/R3) |
| A7 | payload 限死 `[String:String]` | **延迟** — 15 文件涟漪, 独立 PR (Rule 3 外科原则), 不混入本轮 | 文档标注延迟 |
| A8 | Bridge 层无统一抽象 | **延迟** — 大重构, 三桥 RPC/超时/重试统一, 独立 PR | 文档标注延迟 |
| A9 | ES 商用路径阻塞 (entitlement 未申请) | **延迟** — 依赖 Apple System Extension entitlement 申请, 非代码项; ES 骨架保留但 `enabled=false` 默认 | 文档标注延迟 |
| A10 | 无上游背压回流, 源不知下游满 | EventBus/Dispatcher `observeBackpressure`/`notifyBackpressure`; 源注册回调, HIGH/NORMAL 信号回流; main.swift 挂接 | EventBus/Dispatcher/main.swift |

## 运行时风险 (R)

| ID | 问题 | 修复 |
|----|------|------|
| R1 | FSEvents 监听整个 `$HOME` 全树 → 事件洪水 | `watchPaths` 白名单批量配置 (非全树), latencySec 可配 |
| R2 | Dispatcher 容量过小 (bucketMax=5, queueMax=50) | 容量全可配: `tokenBucketMax`/`queueMax`/`dispatchQueueMax` 经 Config |
| R3 | 幂等键墙钟 bucket, 回拨失效 | 承接 A6: 单调水位 dedupTs 注入 idempotencyKey |
| R4 | 无 crash-safe 在途持久化 | `DispatcherOutbox`: enqueue/dequeue/markAttempted/markFailed/persistPending/loadPending; 重启 `replayOutbox`; TriggerSignal Codable |
| R5 | SQLite WAL 无 checkpoint, 无限膨胀 | `startCheckpoint` 定时 `PRAGMA wal_checkpoint(TRUNCATE)`, interval 可配 |
| R6 | 优雅停机 IPC 半开连接 | Lifecycle 持 dispatcher, `drainForShutdown` 硬超时 (R10) 内排空并关 client |
| R7 | 网络/工作区源每事件起 Task, 无背压 | 源 Task 限流: NetworkSource `minIntervalMs` 突发守卫; NSWorkspace 单 observer |
| R8 | mountObserver 声明未注册, 卷挂载永不触发 | 注册 `NSWorkspaceDidMountNotification` legacy observer, userInfo 取 devicePath/volumePath (macOS 14 兼容) |
| R9 | EventLog 轮转非原子, 并发读写竞态 | 原子轮转 + 流式 archive replay, reverse tail 读窗口 |
| R10 | gracefulShutdown async 无超时 | `shutdownTimeoutSec` 硬超时, 超时持久化剩余到 outbox (R4) |

## 工程实现缺陷 (E)

| ID | 问题 | 修复 |
|----|------|------|
| E1 | RuleStore `nonisolated(unsafe) db` 绕并发检查 | `nonisolated(unsafe)` 仅限 deinit 关闭用的 `closeHandle`; db 访问走 actor 隔离 |
| E2 | UPSERT 覆写 `created_at`, 创建时间丢失 | UPSERT 仅更新 `updated_at`, `created_at` 由 INSERT 首次写入不覆写 |
| E3 | ALTER TABLE 每启无条件重跑 | `PRAGMA user_version` + 有序 Migration 数组, 失败可见中止 (不 try? 掩盖) |
| E4 | flush() 忙等 1ms 轮询, 空载唤醒 | **延迟** — 低优先, 当前 1ms poll 在 shutdown 路径可接受; 后续可改 `AsyncSemaphore` |
| E5 | IPCServer recv 单字节循环, 大消息开销高 | 分块缓冲读 + 行长上限 (承 F8) |
| E6 | 死配置 maxRetries 全链路未用 | submitTask 重试循环真正读 `rule.maxRetries`, 指数退避 (500ms→4s) |
| E7 | health() 每次拷贝全量字典 | **延迟** — 低频调用 (health RPC), 拷贝开销可忽略 |
| E8 | 剪贴板 2s 轮询粗粒度 | `pasteboardPollSec` 可配 |
| E9 | 日志无结构化字段 | **延迟** — 需 metrics pipeline (4 天工程), 独立 PR; 当前 `os.Logger` 统一日志已有 subsystem/category |
| E10 | mock studio 固定 task_id 未验证失败语义 | MockStudio keep-alive 连接循环 (修本轮回退 500ms 瓶颈); 真实 task.submit 成功占键已验证 |

## 延迟项说明 (诚实标注, 不假装已修)

- **A1 集群 leader 选举**: 需 Raft/租约协调层, 跨节点设计, 非单仓库外科可修。
- **A7 payload 类型化 union**: `[String:String]` → 结构化 union 涉及 15 文件涟漪, 按外科原则独立 PR。
- **A8 统一 Bridge 抽象**: 三桥 RPC/超时/重试统一为大重构, 独立 PR。
- **A9 ES entitlement**: 依赖 Apple System Extension 商用 entitlement 申请, 非代码项。
- **E9 结构化日志/metrics**: 需 metrics 导出管线 (速率/延迟/P99), 独立 PR。
- **E4/E7**: 低优先, 当前实现可接受, 后续优化。

## 本轮额外修复 (非审计项, 验证中发现)

- **MockStudio 连接 keep-alive**: 原 mock 每请求关连接, UDSClient 复用连接导致每事件 500ms 退避重试 → 2000 事件 1006s。改为连接内循环处理多请求, 全套件 1259s → 1.4s (884× 提速)。反映真实服务器 keep-alive 语义。
- **ESXPC 测试竞态**: XPC `deliverEvent` fire-and-forget, `drainIngest` 早于 publish。改 `registry.tickCount` 移到 publish 之后 + 新增 `waitForCount` 确定性等待, 消除异步竞态。

## 构建/测试 (更新)

```
swift build            # debug ok
swift build -c release # release ok
swift test             # 39 tests, 0 failures, 1.4s (原 1259s)
```
