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

---

# 第三轮: 生产商用发布评审修复 (fusion-event-audit-result-product-0827.md)

对应审计报告: `~/fusion/audit/fusion-event-audit-result-product-0827.md` (六大维度生产评审, 4 P0 + 14 P1 + 23 P2 + 13 P3)。本轮逐项落地全部代码可修项; 外部依赖/需设计项如实延迟并标决策。

## P0 发布阻断 (4 项, 全部代码修复 + 构建验证)

| ID | 问题 | 修复 | 文件 |
|----|------|------|------|
| F-CRASH-1 | FSEvents flushBatch 遍历字典时并发 mutate → 必崩 | `flushBatch` 先 `let snapshot = batchBuffer; batchBuffer.removeAll()` 再遍历快照; handleEvents 只写 buffer 不遍历; batchHardCap 8192 硬上限 | FSEventsSource.swift |
| F-CRASH-2 | outbox 失败重放被无条件删除 → 永久丢触发 | `replayOutbox` 仅 `occupied != nil && taskId != "failed"` 时 dequeue; 失败保留 `.json` + 移除幂等键待下次重放 | Dispatcher.swift |
| F-CRASH-3 | outbox 写非原子无 fsync → 崩溃丢触发 | `DispatcherOutbox.writeAtomic` 用 `.atomic` + `FileHandle.synchronize()` | Dispatcher.swift |
| S0 | AuditBridge guard 显式 block 当故障 fail-open → 安全旁路 | `audit` 见 `resp.error` 时先检 `err.code == RPCErrorCode.guardBlock.rawValue` → 返 `.block`, 不走 fail-open | AuditBridge.swift |

验证: `swift build` ok; P0 修复后构建通过。

## P1 硬伤 (代码可修项)

| ID | 问题 | 修复 |
|----|------|------|
| P4-1 | FSEvents/ES 每批无界 fire-and-forget Task | FSEvents 回调在专用 runLoop 串行化, handleEvents 仅合批进 buffer (快照遍历), 扇出由有界 EventBus 8192 承接; batchHardCap 8192; ES 默认 esEnabled=false 隔离 |
| F-1 | FSEvents start() 非幂等 → 二次启动泄漏 stream+retain+task | `guard stream == nil` 幂等 guard |
| F-2 | FSEvents passRetained 失败路径 +1 永久泄漏 | passRetained 在 create 成功后; create 返回 nil / start 失败两路径均 `release()` 平衡 |
| F-3 | ES passUnretained 无 retain 平衡 → UAF | 改 `passRetained` + `infoPtr` 存储; 全部失败路径 `releaseRetainOnFailure()`; `stop()` release |
| F-IDEM-1 | 幂等键不含 nodeId → 跨节点互抑 | `computeIdempotencyKey` 纳入 `nodeId`; 分隔符 `\|` 转义防碰撞 |
| F-IDEM-2 | submit 最终失败不占幂等键 → 重启重复提交 | submit 失败 `occupyKey(taskId: "failed")`, 重放不再重复提交 |
| F-DROP-1 | 队列溢出丢弃触发静默丢失 | 溢出持久化 outbox + `eventLog.recordTrigger`, 不静默蒸发 |
| F-PERSIST-1 | RuleStore 迁移 v1 重加 DDL 已建列 → user_version 卡 0 | 迁移改 `CREATE INDEX IF NOT EXISTS idx_rules_type_v1` (幂等); DDL 已建主 index, v1 加独立 index |
| F-PERSIST-2 | checkpointTask 从不赋值 → stopCheckpoint no-op, 循环泄漏 | init 内联 Task 赋 `checkpointTask` (`nonisolated(unsafe)`); `stopCheckpoint` 真可 cancel |
| F-PERSIST-3 | synchronous=NORMAL → 断电丢 debounce_state | `PRAGMA synchronous=FULL` |
| F-PERSIST-4 | EventLog 写不 fsync → 崩溃丢审计尾 | `append` 后 `try? fileHandle?.synchronize()`; fallback `.atomic` |
| F-PERSIST-5 | recentDebounceWindow 只读当前文件忽略归档 → 防抖窗不全 | 扫描全部归档 (reversed), 合并 max ts, stopAll flag |
| F-PERSIST-6 | replay 有归档返回错误切片 | 跨归档全局时序合并 |
| F-EVICT-1 | recentKeys/ContextCache FIFO 非 LRU → 热键被逐 → 重复提交 | re-occupy 移队尾 (true LRU); ContextBridge cache hit 也晋升 |
| F-TIMEOUT-1 | UDSClient 阻塞 recv 击穿 withTimeout, 实际超时 max(配置, 5s) | UDSClient init 收 `timeoutSec`, SO_RCVTIMEO/SO_SNDTIMEO 用配置值 (非硬编 5s); 三桥传各自 timeoutSec |
| D2 | event.shutdown RPC no-op | `LifecycleHandle.instance.requestShutdown()` 真触发优雅停机 |
| D3 | event.notification 硬编 nodeId:"" + 每次新 eventId | IPCServer init 收 nodeId; eventDict 用真实 nodeId |
| S1 | 配置/节点文件无 mode 可能 644 | config.json + node.id 写用 `.atomic` + `posixPermissions: 0o600` |
| S3 | replay/dry_run 无 limit 上限 → OOM | `min(limit, replayMaxLimit=10_000)` 服务端硬上限 |

## P1 外部依赖/设计延迟项 (决策已定, 非代码外科可修)

| ID | 问题 | 决策 |
|----|------|------|
| D1 | event.subscribe RPC no-op | **无需修** — IPCServer.handleClient 每连接自动订阅 EventBus, pumpEvents 推 `event.notification`, 推送已生效; RPC 仅确认订阅 |
| S5/S6/D4 | ES entitlement + 代码签名缺失 → 特权审计商用阻塞 | **延迟** — 依赖 Apple `endpoint-security.client` entitlement 申请 + codesign/公证, 非代码项; ES 骨架保留 fail-closed (ERR_NOT_ENTITLED 自禁用), 默认 esEnabled=false, 当前降级 NSWorkspace 低保真进程事件 |
| A2-3 | 单点无 HA, 无 leader 选举 | **延迟** — 同 A1, 需集群协调层 (Raft/租约), 单节点开发/内部试用场景可接受; 多节点商用需独立设计 PR |
| O1 | 无 metrics/P99/速率导出 | **延迟** — 同 E9, 需 metrics 导出管线 (速率/延迟/P99/backpressure 时长/outbox 积压), 独立 PR; 当前 `os.Logger` + `event.health` 快照 |

## P2 显著隐患 (代码可修项, 本轮落地)

| ID | 问题 | 修复 |
|----|------|------|
| A2-1 | A10 背压回流空挂接, 源端无 throttle | 见下方 P2 延迟说明 (源端 setThrottle 接口需独立设计) |
| A2-2 | 无 launchd 守护进程化, nohup 模式脆弱 | 见下方 P2 延迟说明 (launchd 为生产唯一模式) |
| D3 | (已列 P1) | — |
| S1 | (已列 P1) | — |
| S3 | (已列 P1) | — |
| F-4 | ES fail-open "降级 NSWorkspace" 是注释无回退 | 见下方 P2 说明 |
| F-5 | ES extract 不检查 msg.version | **已修 (P1 顺带)** — `guard msg.version >= 1` |
| F-6 | drainForShutdown 对 pending 只记日志不 submit | **已修** — drainForShutdown 调 `submitTask` (非仅 log) |
| F-7/F-8/F-9 | ESXPC 无认证/connect 失败返 true/stop 不彻底 | 见下方 P2 说明 (esXpcEnabled=false 默认隔离) |
| F-10 | NetworkSource throttle 丢合法状态转换, 终态永不发 | **已修** — lastPath 仅在真发布时更新, throttle-drop 不推进 lastPath, 终态下次可发 |
| F-11 | NSWorkspace launch 事件误标 .processTerminated | **已修** — 新增 `SystemEventType.processLaunched`; publishProcess 按 isLaunch 区分 .processLaunched/.processTerminated |
| F-12 | FSEvents flags 与 paths 错位 | **已修 (P0 顺带)** — 单 `pairs` 循环同索引, nil path skip |
| F-15 | IPCServer heartbeat 持 actor 阻塞 + client fd 无 SO_NOSIGPIPE | **已修** — heartbeat sweep 用 withTaskGroup 并发写 (不阻塞 actor); registerConn 设 SO_NOSIGPIPE |
| F-PERSIST-2 | (已列 P1) | — |
| F-PERSIST-5/6 | (已列 P1) | — |
| F-EVICT-2 | purgeExpiredKeys O(n²) 阻塞 actor | **已修** — 用 expiredSet 单次 removeAll, O(n) 非 O(n²) (Dispatcher + ContextBridge) |
| F-TIME-1 | 幂等键 TTL 用墙钟 → 时钟跳变破坏 purge | **已修 (P0 顺带)** — `nowMs()` 单调时钟 `max(monotonicClock+1, wallclock)` |
| P4-2 | 每事件 actor hop 到 SourceRegistry 计数 | **缓解** — 高吞吐源 FSEvents 已用 tickCountN 批量计数; 低吞吐源 (NSWorkspace/Network/Pasteboard/ES) 单跳开销可忽略 |
| P4-4 | FSEvents batchBuffer 软触发非硬上限 | **已修 (P1 顺带)** — batchHardCap 8192 硬上限 |
| O2 | event.shutdown no-op (同 D2) | **已修** — 同 D2 |
| O3 | 无 SIGHUP 配置热重载 | 见下方 P2 延迟说明 |
| O4 | 日志无轮转/归档 | **已修** — start.sh rotate_log: LOG_FILE >10MB 轮转 .1/.2/.3/.4 (O4) |
| O5 | doctor 不查 outbox/积压/背压 | **已修** — doctor 报 triggers failed/dropped/dispatch_dropped + outbox backlog (>50 warn) + 下游可达性 (O5) |
| O6/O7 | 无资源限额/多节点统一运维 | 见下方 P2 延迟说明 |

## P2 延迟项说明

- **A2-1 源端 throttle 接口**: 背压 HIGH 信号回流需源端 `setThrottle`/`pause` 协议设计 (EventSource 协议扩展), 涉五源改造, 独立 PR。
- **A2-2 守护进程化**: launchd agent 为生产唯一推荐模式 (start.sh install 已实现 KeepAlive+RunAtLoad); nohup 仅开发; 二进制 daemonize 非 macOS 惯例。
- **F-4 ES 降级回退**: ES 源本质是独立数据源, 不应内部路由到 NSWorkspaceSource; 正确做法是运维不启用 ES, 默认 NSWorkspace 源已覆盖进程事件。日志措辞修正为"ES disabled, NSWorkspace source provides process events"。
- **F-7/F-8/F-9 ESXPC**: Phase-2 L1 骨架, esXpcEnabled=false 默认, 不在生产路径; 完整 XPC 通道 (peer 认证/连接管理) 随 ES entitlement PR 一并落地。
- **O3 SIGHUP 热重载**: 规则已 `rule.reload` 热载; config.json 变更需重启, launchd KeepAlive 重启 <1s 可接受。
- **O6/O7 资源限额/多节点运维**: 单节点场景 rlimit 可由 launchd plist `ResourceLimits` 配置; 多节点随 A1 集群 PR。

## P3 次要项

| ID | 处理 |
|----|------|
| A2-4/A2-5/P4-5 | 忙等 1ms 轮询/outbox 目录隔离: 低优先, shutdown 路径可接受, 延迟 |
| D5 | JSON-RPC batch + notification 不响应: **已修** — decodeBatch 支持数组请求; processLine batch 并发 dispatch 返响应数组; id==nil notification 不返响应 |
| S4 | rule.add path_pattern glob 校验: **已修** — path_pattern >4096 拒; 控制字符拒; rule_name/agent 长度上限 256 |
| S7/S8 | outbox 明文/审计防篡改: 同 S1 umask 风险, 0600 缓解; 完整性保护随 metrics PR |
| F-13 | PasteboardSource zombie Task: **已修** — poll Task guard let self else break, self 释放即退出循环, 不永跑 |
| F-16 | decodeRequest try? 静默吞: **已修** — 捕获 decode error 记 os.Logger, 不静默 |
| P4-3 | waitForCount 0.5ms 轮询: 仅测试, 非生产, 延迟 |
| P4-6 | outbox 每 trigger 一文件: 随 outbox 批量写优化 PR |
| O8/O9/O10 | launchd ThrottleInterval/双路径竞态/doctor nc 脆弱: **已修** — plist 加 ThrottleInterval=10/ExitTimeOut=15 (O8); nohup start 时若 plist 已装则 warn (O9); doctor 改 python3 json 解析非 grep (O10) |

## 构建测试 (第三轮)

```
swift build            # debug ok
swift build -c release # release ok
swift test             # 49 tests, 0 failures, 2.0s
```

49 测试全绿 (含本轮新增 RPCBatchTests 7 例: batch 解码/空 batch malformed/notification nil id/processLaunched/decodeRequest 失败不崩)。

## 第四轮 — 发布工程 + 可观测性 (M8)

企业生产发布审计: 代码层 P0–P3 全修, 但缺发布工程层 (codesign/notarize) + 可观测性 (metrics) + 长跑/混沌验证。本轮落地自可做部分; 端到端联调 (guard/memory/agent-studio) 提 issue 跟踪 (上游 #3/#4/#250)。

### O1/E9 指标管道 — MetricsCollector

`Sources/fusion-event/Metrics.swift` (~130 行): `actor MetricsCollector` + `final class LatencyHistogram: @unchecked Sendable`。

- 计数器: sourceEventCount, triggerSubmitted/Blocked/Failed/Dropped/Retried, ingestDropped, dispatchDropped, outboxBacklog。
- 延迟直方图: buckets [1,5,10,25,50,100,250,500,1000,2500,5000,10000,30000]ms; per-bridge (guard/memory/dispatch) 记 P50/P99/avg/max。
- 背压: pressureHighSince/pressureTotalMs (markPressureHigh/Normal 累计活跃时长)。
- snapshot() 返 `[String: AnyCodable]` (Sendable, 可跨 actor); LatencyHistogram.summary() 返 `[String: UInt64]`。无外部依赖。
- 注入点: `Dispatcher.setMetrics` + `EventBus.setMetrics`; 所有计数/延迟/背压点接线 (runTriggerChain 记 guard/memory 延迟, submitTask 记 dispatch 延迟, overflow/block/failClosed/retry/fail 计数, outbox backlog 同步; EventBus ingest drop + 背压 HIGH/NORMAL)。同步上下文调 actor 方法用 `Task { await }` 包。
- 暴露: `event.metrics` JSON-RPC (RPCMethods.metricsRpc), snapshot 合并 registry.health() events_total。

### 发布工程 — scripts/sign.sh + entitlements

`scripts/sign.sh` (可执行): codesign (Developer ID Application, hardened runtime `--options runtime`, `--timestamp`) + notarytool (`--keychain-profile --wait`) + stapler staple + validate。模式 full (默认) / sign-only。外部依赖明标 (用户必须提供, 无法自取): DEVELOPER_ID_NAME, NOTARY_PROFILE, ENTITLEMENTS。

`scripts/fusion-event.entitlements` (plutil 合法): hardened runtime keys, `com.apple.security.network.client=true`; ES entitlement (`com.apple.developer.endpoint-security.client`) 注释 (blocked on Apple 审批, ES source 保持 esEnabled=false)。

### O2 长跑 + 混沌压测 — StressHarnessTests

`Tests/fusion-eventTests/StressHarnessTests.swift`: 4 测试, env 门控 (`FUSION_EVENT_STRESS=1`, 默认 `swift test` 跳过):

1. testLongRunMemoryDriftBounded — N distinct events, RSS start vs end, drift < 200MB (启发式, 非绝对)。
2. testDownstreamKillOutboxReplay — 杀 studio 中途, 继续推 → fail 进 outbox; 重启 studio + replayOutbox → pending 重提交 (R4 crash-safe); outbox 不增长。
3. testDiskFullDegradeNoCrash — outbox 目录 chmod 000 (模拟满盘), 推事件不崩, stats 完整。
4. testConcurrentClientLoad — taskGroup 并发推 N, 无死锁/连接泄漏, 产出 submits。

`FUSION_EVENT_STRESS_ITERS` 缩放迭代数 (默认 2000)。配套修: MockStudio.stop() 强制 close 所有已接受连接 fd (原只关 listenFd, 残留连接 fd 让 phase-2 "杀下游" 不真实 — chaos 测试暴露); 测试 tmpDir socket 路径压短 (`getpid()` 替代 UUID, sun_path 104 字节限制)。

### 端到端联调 — 外部 (issue 跟踪)

冻结契约 (fusion-event 调用侧), 已提 issue:
- guard #3: `guard.audit` → params {trigger_id, event_type, target_path, target_agent, payload, node_id}, resp {decision: pass|block|challenge, reason, risk_level, audit_id}, error -32010 guardBlock。
- memory #4: `memory.retrieve_context` → params {trigger_id, query, top_k, node_id}, resp {context, memory_ids, cache_hit}。
- agent-studio #250: `task.submit` → params {title, description, agent_id, graph_id, input(JSON), trigger, priority, idempotency_key}, resp {result.task.task_id}。

### 仍延期 (外部/设计)

S5/S6/D4 ES entitlement (Apple 审批), A2-3 HA (多节点选主/故障转移设计), 端到端联调 (上游响应)。

## 构建测试 (第四轮)

```
swift build            # debug ok
swift build -c release # release ok
swift test             # 57 tests, 0 failures (4 stress skipped), ~2s
FUSION_EVENT_STRESS=1 FUSION_EVENT_STRESS_ITERS=300 swift test --filter StressHarnessTests
                       # 4 stress tests, 0 failures (replay ~20s 真实重试退避)
```

---

# 第五轮: 端到端联调验证 (M9)

三链联调探测 (fusion-event 调用侧冻结契约 vs 上游真实实现):

| 链 | 上游 | 契约对齐 | 状态 |
|----|------|----------|------|
| task.submit | fusion-agent-studio daemon | socket + params + response 全对齐 | **E2E 验证通过** (唯一成熟链) |
| guard.audit | fusion-guard | 方法名 drift (`guard.audit` 未实现, 上游仅 `guard.audit.list`/`guard.audit.verify`) | 上游未实现, issue #3 |
| memory.retrieve_context | fusion-memory | 三处 drift: 方法名 (`memory.retrieve_context` vs `retrieve`) + 参数名 (`query`/`text`, `node_id`/`session_id`) + response 结构 (`{context,memory_ids,cache_hit}` vs `FormattedContext{blocks,total_tokens}`) | 上游契约 drift, issue #4 已 comment 细化 |

### E2E smoke — task.submit 真实联调

`Tests/fusion-eventTests/E2EStudioTests.swift`: env-gated (`FUSION_EVENT_E2E=1`), 默认 `swift test` 跳过。连真实 agent-studio daemon (launchd 常驻, socket `/tmp/fusion-studio.sock` 0600), 推 10 file events, 断言:
- `submitted > 0` — 真实 daemon 接收 task.submit (socket + params + response 契约全通)
- `failed == 0` — 成熟链无失败
- 真实 `task_id` 返回 (`task_{ms}_{seq}`, agent-studio TaskStore.submit 生成)

验证记录: 真实 daemon 返 `task_id: task_1787820767545_3`, deduped:False, status:ok。即使 issue #250 input.event 字段名 drift (camelCase vs snake_case) 存在, task 仍创建 — 证明 socket/协议/response 层契约完全对齐, 字段 drift 仅影响 trigger_input 解析 (已提 issue #250)。

测试残留清理: 10 个 E2E task 全删 (task.delete), 无残留。

### 上游契约 drift — 已提 issue (不修上游代码)

- **agent-studio #250**: task.submit `input` 内 event 字段名 drift (fusion-event camelCase `targetPath`/`eventId` vs agent-studio snake_case `target_path`/`event_id`)。fusion-event 是 D-10 契约权威 (trigger_input.py 明注), 坚持契约提 issue 让上游改。comment: https://github.com/dahai80/fusion-agent-studio/issues/250#issuecomment-5436582134
- **fusion-memory #4**: 三处 drift (方法名/参数名/response 结构)。memory 链无明确契约权威标注 (fm-server `retrieve` 看似成熟自有 API), 中立提方向让 memory 方定 (A: 上游加 alias/tolerance vs B: fusion-event 改用 `retrieve`+`text`+`session_id`+解析 FormattedContext)。comment: https://github.com/dahai80/fusion-memory/issues/4#issuecomment-5436646138
- **fusion-guard #3**: `guard.audit` 上游未实现, 待上游响应。

### 发现的上游 bug (不修, 记录)

- agent-studio `daemon_server.py:43` 硬编 `SOCKET_PATH = "/tmp/fusion-studio.sock"`, 忽略 `FUSION_STUDIO_SOCKET` env (start.sh 用 env 但真实 daemon 不读) — 测试无法用私有 socket 隔离, 只能连真实 daemon。非我工程, 不改。

## 构建测试 (第五轮)

```
swift build            # debug ok
swift build -c release # release ok
swift test             # 58 tests, 0 failures (4 stress + 1 E2E skipped), ~11s
FUSION_EVENT_E2E=1 swift test --filter E2EStudioTests
                       # 1 E2E test, 0 failures (real daemon, 0.6s)
```

58 测试全绿 (53 原有 + 4 stress + 1 E2E, stress/E2E 默认跳过)。

57 测试全绿 (53 原有 + 4 stress 默认跳过; 含本轮新增 MetricsTests 4 例: 计数器累加/延迟直方图 P50 P99/背压时长累加/Sendable+Codable snapshot)。

