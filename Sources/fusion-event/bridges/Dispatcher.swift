import Foundation
import os.lock

public actor Dispatcher: TriggerSink {
    private let sockPath: String
    private let timeoutSec: Int
    private let tokenBucketMax: Int
    private var availableTokens: Int
    private var pendingQueue: [TriggerSignal] = []
    private var recentKeys: [String: (taskId: String, expiryTs: UInt64)] = [:]
    private var recentKeyOrder: [String] = []
    private var keyTtlMs: UInt64 = 60_000
    private let keyMaxEntries: Int = 10_000
    private let queueMax: Int
    private var client: UDSClient?
    private var auditBridge: AuditBridge?
    private var contextBridge: ContextBridge?
    private let eventLog: EventLog
    private let outbox: DispatcherOutbox
    private var submittedCount: UInt64 = 0
    private var blockedCount: UInt64 = 0
    private var failedCount: UInt64 = 0
    private var droppedCount: UInt64 = 0
    private var retriedCount: UInt64 = 0
    private var pressureActive: Bool = false
    private var pressureObservers: [@Sendable () async -> Void] = []
    private var shuttingDown = false
    private var monotonicClock: UInt64 = 0
    private var metrics: MetricsCollector?

    init(
        sockPath: String,
        timeoutSec: Int,
        tokenBucketMax: Int,
        queueMax: Int,
        eventLog: EventLog,
        outboxDir: String
    ) {
        self.sockPath = sockPath
        self.timeoutSec = timeoutSec
        self.tokenBucketMax = tokenBucketMax
        self.availableTokens = tokenBucketMax
        self.queueMax = queueMax
        self.eventLog = eventLog
        self.outbox = DispatcherOutbox(dir: outboxDir)
    }

    public func setBridges(audit: AuditBridge, context: ContextBridge) {
        self.auditBridge = audit
        self.contextBridge = context
    }

    public func setMetrics(_ m: MetricsCollector) {
        self.metrics = m
    }

    public func observeBackpressure(_ handler: @escaping @Sendable () async -> Void) {
        pressureObservers.append(handler)
    }

    private func notifyBackpressure(active: Bool) {
        guard active != pressureActive else { return }
        pressureActive = active
        let level = active ? "HIGH" : "NORMAL"
        FusionLog.bridge.notice("backpressure \(level) queue=\(self.pendingQueue.count)/\(self.queueMax) tokens=\(self.availableTokens)/\(self.tokenBucketMax) (A10)")
        let now = nowMs()
        let metricsRef = metrics
        if active {
            Task { await metricsRef?.markPressureHigh(now: now) }
        } else {
            Task { await metricsRef?.markPressureNormal(now: now) }
        }
        let observers = pressureObservers
        Task {
            for h in observers { await h() }
        }
    }

    private func nowMs() -> UInt64 {
        monotonicClock = max(monotonicClock + 1, UInt64(Date().timeIntervalSince1970 * 1000))
        return monotonicClock
    }

    public func onTrigger(_ signal: TriggerSignal) async {
        let now = nowMs()
        purgeExpiredKeys(now: now)
        if recentKeys[signal.idempotencyKey] != nil {
            FusionLog.bridge.notice("duplicate trigger suppressed idem=\(signal.idempotencyKey, privacy: .public) (H1)")
            return
        }
        if availableTokens > 0 {
            availableTokens -= 1
            await runTriggerChain(signal: signal, now: now)
            availableTokens += 1
            await drainQueue(now: now)
        } else {
            if pendingQueue.count >= queueMax {
                let dropped = pendingQueue.removeFirst()
                droppedCount += 1
                await metrics?.recordTriggerDropped()
                FusionLog.bridge.error("trigger queue overflow (max \(self.queueMax)), drop oldest \(dropped.triggerId, privacy: .public) (F-DROP-1: persist)")
                outbox.enqueue(signal: dropped)
                await eventLog.recordTrigger(
                    triggerId: dropped.triggerId, taskId: nil,
                    idempotencyKey: dropped.idempotencyKey, event: dropped.event,
                    matchedRules: [dropped.rule.ruleName]
                )
            }
            pendingQueue.append(signal)
            FusionLog.bridge.notice("trigger queue backlog, \(self.pendingQueue.count, privacy: .public) waiting (R1)")
        }
        notifyBackpressure(active: pendingQueue.count >= queueMax * 3 / 4 || availableTokens == 0)
    }

    private func drainQueue(now: UInt64) async {
        guard !pendingQueue.isEmpty, availableTokens > 0, !shuttingDown else { return }
        let next = pendingQueue.removeFirst()
        availableTokens -= 1
        await runTriggerChain(signal: next, now: now)
        availableTokens += 1
        notifyBackpressure(active: pendingQueue.count >= queueMax * 3 / 4 || availableTokens == 0)
        await drainQueue(now: now)
    }

    private func runTriggerChain(signal: TriggerSignal, now: UInt64) async {
        guard let audit = auditBridge else {
            FusionLog.bridge.error("auditBridge nil, skip \(signal.triggerId)")
            return
        }
        let auditStart = nowMs()
        let outcome = await audit.audit(signal: signal)
        await metrics?.recordLatency(bridge: "guard", ms: nowMs() - auditStart)
        switch outcome {
        case .block(let res):
            blockedCount += 1
            await metrics?.recordTriggerBlocked()
            FusionLog.bridge.notice("guard block \(signal.triggerId, privacy: .public): \(res.reason)")
            occupyKey(signal.idempotencyKey, taskId: "blocked", now: now)
            await eventLog.recordTrigger(
                triggerId: signal.triggerId, taskId: nil,
                idempotencyKey: signal.idempotencyKey, event: signal.event,
                matchedRules: [signal.rule.ruleName]
            )
            outbox.dequeue(triggerId: signal.triggerId)
            return
        case .failClosed(let reason):
            blockedCount += 1
            await metrics?.recordTriggerBlocked()
            FusionLog.bridge.error("fail-closed \(signal.triggerId, privacy: .public): \(reason)")
            occupyKey(signal.idempotencyKey, taskId: "failclosed", now: now)
            await eventLog.recordTrigger(
                triggerId: signal.triggerId, taskId: nil,
                idempotencyKey: signal.idempotencyKey, event: signal.event,
                matchedRules: [signal.rule.ruleName]
            )
            outbox.dequeue(triggerId: signal.triggerId)
            return
        case .pass, .degradedFailOpen, .challenge:
            break
        }
        let ctxStart = nowMs()
        let ctx = await contextBridge?.retrieveContext(signal: signal) ?? ContextResult(context: "", memoryIds: [], cacheHit: false, contextStale: false)
        await metrics?.recordLatency(bridge: "memory", ms: nowMs() - ctxStart)
        await submitTask(signal: signal, context: ctx, now: now)
    }

    private func submitTask(signal: TriggerSignal, context: ContextResult, now: UInt64) async {
        let submitStart = nowMs()
        let input: [String: Any] = [
            "trigger_id": signal.triggerId,
            "event": eventDict(signal.event),
            "context": context.context,
            "rule_name": signal.rule.ruleName,
            "node_id": signal.nodeId
        ]
        let inputJSON = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let params: [String: Any] = [
            "title": "event:\(signal.rule.ruleName)",
            "description": "\(signal.event.type.rawValue) @ \(signal.event.targetPath ?? "")",
            "agent_id": signal.rule.targetAgent,
            "graph_id": signal.rule.targetGraphId ?? "",
            "input": inputJSON,
            "trigger": "immediate",
            "priority": 0,
            "idempotency_key": signal.idempotencyKey
        ]
        let req = RPCRequest(method: "task.submit", params: AnyCodable(params), id: .int(Int.random(in: 1...Int.max)))
        if !outbox.exists(triggerId: signal.triggerId) {
            outbox.enqueue(signal: signal)
        }
        let maxRetries = max(0, signal.rule.maxRetries)
        var attempt = 0
        while true {
            do {
                let resp = try await callWithTimeout(req)
                var taskId: String? = nil
                if let res = resp.result?.value as? [String: Any], let task = res["task"] as? [String: Any] {
                    taskId = task["task_id"] as? String
                }
                occupyKey(signal.idempotencyKey, taskId: taskId ?? "unknown", now: now)
                submittedCount += 1
                await metrics?.recordTriggerSubmitted()
                await metrics?.recordLatency(bridge: "dispatch", ms: nowMs() - submitStart)
                await metrics?.setOutboxBacklog(outbox.pendingCount())
                outbox.dequeue(triggerId: signal.triggerId)
                FusionLog.bridge.info("task.submit ok trigger=\(signal.triggerId, privacy: .public) task=\(taskId ?? "?") idem=\(signal.idempotencyKey, privacy: .public)")
                await eventLog.recordTrigger(
                    triggerId: signal.triggerId, taskId: taskId,
                    idempotencyKey: signal.idempotencyKey, event: signal.event,
                    matchedRules: [signal.rule.ruleName]
                )
                return
            } catch let err as UDSClientError {
                await resetClient()
                outbox.markAttempted(triggerId: signal.triggerId, error: "\(err)")
                if attempt < maxRetries && isRetryable(err) {
                    attempt += 1
                    retriedCount += 1
                    await metrics?.recordTriggerRetried()
                    let backoffNs = UInt64(min(500 * Int(pow(2.0, Double(attempt - 1))), 4000)) * 1_000_000
                    FusionLog.bridge.notice("task.submit retry attempt=\(attempt)/\(maxRetries) trigger=\(signal.triggerId) backoff=\(backoffNs / 1_000_000)ms (E6: maxRetries honored)")
                    try? await Task.sleep(nanoseconds: backoffNs)
                    continue
                }
                failedCount += 1
                await metrics?.recordTriggerFailed()
                await metrics?.setOutboxBacklog(outbox.pendingCount())
                outbox.markFailed(triggerId: signal.triggerId, error: "\(err)")
                occupyKey(signal.idempotencyKey, taskId: "failed", now: now)
                switch err {
                case .connectionFailed:
                    FusionLog.bridge.error("task.submit fail agent-studio not running, retries exhausted trigger=\(signal.triggerId)")
                case .timeout:
                    FusionLog.bridge.error("task.submit timeout, retries exhausted trigger=\(signal.triggerId)")
                default:
                    FusionLog.bridge.error("task.submit io error, retries exhausted trigger=\(signal.triggerId)")
                }
                await eventLog.recordTrigger(
                    triggerId: signal.triggerId, taskId: nil,
                    idempotencyKey: signal.idempotencyKey, event: signal.event,
                    matchedRules: [signal.rule.ruleName]
                )
                return
            } catch {
                failedCount += 1
                await metrics?.recordTriggerFailed()
                await metrics?.setOutboxBacklog(outbox.pendingCount())
                outbox.markFailed(triggerId: signal.triggerId, error: "\(error)")
                occupyKey(signal.idempotencyKey, taskId: "failed", now: now)
                FusionLog.bridge.error("task.submit unknown error, retries exhausted trigger=\(signal.triggerId)")
                return
            }
        }
    }

    private func isRetryable(_ err: UDSClientError) -> Bool {
        switch err {
        case .connectionFailed, .timeout:
            return true
        case .ioError:
            return true
        }
    }

    private func eventDict(_ e: SystemEvent) -> [String: Any] {
        [
            "event_id": e.eventId,
            "type": e.type.rawValue,
            "target_path": e.targetPath ?? "",
            "timestamp": e.timestamp,
            "payload": e.payload,
            "node_id": e.nodeId
        ]
    }

    private func occupyKey(_ key: String, taskId: String, now: UInt64) {
        if recentKeys[key] != nil {
            recentKeyOrder.removeAll { $0 == key }
        }
        recentKeyOrder.append(key)
        recentKeys[key] = (taskId, now + keyTtlMs)
        if recentKeys.count > keyMaxEntries {
            let evictKey = recentKeyOrder.removeFirst()
            recentKeys.removeValue(forKey: evictKey)
        }
    }

    private func purgeExpiredKeys(now: UInt64) {
        var expired: [String] = []
        for (k, v) in recentKeys where v.expiryTs <= now {
            expired.append(k)
        }
        guard !expired.isEmpty else { return }
        let expiredSet = Set(expired)
        for k in expired {
            recentKeys.removeValue(forKey: k)
        }
        recentKeyOrder.removeAll { expiredSet.contains($0) }
    }

    private func resetClient() async {
        guard client != nil else { return }
        FusionLog.bridge.error("dispatcher reset studio client, discard poisoned connection")
        await client?.close()
        client = nil
    }

    private func callWithTimeout(_ req: RPCRequest) async throws -> RPCResponse {
        try await withTimeout(seconds: timeoutSec) { [weak self] in
            guard let self else { throw UDSClientError.connectionFailed }
            let c = await self.ensureClient()
            return try await c.call(req)
        }
    }

    private func ensureClient() -> UDSClient {
        if let c = client { return c }
        let c = UDSClient(sockPath: sockPath, timeoutSec: timeoutSec)
        client = c
        return c
    }

    public func drainForShutdown(timeoutSec: Int) async {
        shuttingDown = true
        let pending = pendingQueue
        pendingQueue.removeAll()
        let startWall = UInt64(Date().timeIntervalSince1970)
        let deadline = startWall + UInt64(timeoutSec)
        if !pending.isEmpty {
            FusionLog.bridge.notice("shutdown drain: \(pending.count) pending triggers, attempting submit within \(timeoutSec)s (R10: hard timeout)")
        }
        var drained = 0
        for sig in pending {
            if UInt64(Date().timeIntervalSince1970) >= deadline {
                FusionLog.bridge.error("shutdown timeout reached, \(drained) drained, persisting rest to outbox (R10)")
                break
            }
            await submitTask(signal: sig, context: ContextResult(context: "", memoryIds: [], cacheHit: false, contextStale: false), now: nowMs())
            drained += 1
        }
        var rest: [TriggerSignal] = []
        for sig in pending where !outbox.exists(triggerId: sig.triggerId) && recentKeys[sig.idempotencyKey] == nil {
            rest.append(sig)
        }
        outbox.persistPending(pending: rest)
        await client?.close()
        client = nil
        FusionLog.bridge.notice("shutdown drain done, outbox entries=\(self.outbox.pendingCount()) (R4: crash-safe replay)")
    }

    public func replayOutbox() async {
        let pending = outbox.loadPending()
        guard !pending.isEmpty else { return }
        FusionLog.bridge.notice("replaying \(pending.count) outbox triggers on restart (R4)")
        for sig in pending {
            let now = nowMs()
            purgeExpiredKeys(now: now)
            if recentKeys[sig.idempotencyKey] != nil {
                outbox.dequeue(triggerId: sig.triggerId)
                FusionLog.bridge.info("outbox trigger \(sig.triggerId) already satisfied, skip")
                continue
            }
            await runTriggerChain(signal: sig, now: now)
            let occupied = recentKeys[sig.idempotencyKey]
            if let occ = occupied, occ.taskId == "failed" {
                FusionLog.bridge.error("outbox trigger \(sig.triggerId) replay failed, keep for next restart (F-CRASH-2: no unconditional delete)")
                recentKeys.removeValue(forKey: sig.idempotencyKey)
                recentKeyOrder.removeAll { $0 == sig.idempotencyKey }
            } else if occupied != nil {
                outbox.dequeue(triggerId: sig.triggerId)
            }
        }
    }

    public func stats() -> [String: UInt64] {
        ["submitted": submittedCount, "blocked": blockedCount, "failed": failedCount, "dropped": droppedCount, "retried": retriedCount]
    }
}

final class DispatcherOutbox: @unchecked Sendable {
    private let dir: String
    private let queueDir: String
    private let lock = OSAllocatedUnfairLock(initialState: ())

    init(dir: String) {
        self.dir = dir
        self.queueDir = "\(dir)/outbox"
        try? FileManager.default.createDirectory(atPath: queueDir, withIntermediateDirectories: true)
    }

    private func pathFor(_ triggerId: String) -> String {
        let safe = triggerId.replacingOccurrences(of: "/", with: "_")
        return "\(queueDir)/\(safe).json"
    }

    private func writeAtomic(_ data: Data, to path: String) {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            if let fh = try? FileHandle(forUpdating: URL(fileURLWithPath: path)) {
                try? fh.synchronize()
                try? fh.close()
            }
        } catch {
            FusionLog.bridge.error("outbox atomic write fail \(path, privacy: .public): \(error)")
        }
    }

    func exists(triggerId: String) -> Bool {
        FileManager.default.fileExists(atPath: pathFor(triggerId))
    }

    func enqueue(signal: TriggerSignal) {
        let p = pathFor(signal.triggerId)
        let enc = JSONEncoder()
        if let data = try? enc.encode(signal) {
            writeAtomic(data, to: p)
            FusionLog.bridge.debug("outbox enqueue \(signal.triggerId, privacy: .public)")
        }
    }

    func dequeue(triggerId: String) {
        try? FileManager.default.removeItem(atPath: pathFor(triggerId))
    }

    func markAttempted(triggerId: String, error: String) {
        let p = pathFor(triggerId) + ".attempt"
        if let data = error.data(using: .utf8) { writeAtomic(data, to: p) }
    }

    func markFailed(triggerId: String, error: String) {
        let p = pathFor(triggerId) + ".failed"
        if let data = error.data(using: .utf8) { writeAtomic(data, to: p) }
        FusionLog.bridge.error("outbox trigger \(triggerId) failed persist, awaiting replay")
    }

    func persistPending(pending: [TriggerSignal]) {
        for sig in pending {
            let p = pathFor(sig.triggerId)
            if !FileManager.default.fileExists(atPath: p) {
                let enc = JSONEncoder()
                if let data = try? enc.encode(sig) {
                    writeAtomic(data, to: p)
                }
            }
        }
        FusionLog.bridge.notice("outbox persisted \(pending.count) pending triggers for replay (R4)")
    }

    func loadPending() -> [TriggerSignal] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: queueDir) else { return [] }
        let dec = JSONDecoder()
        var out: [TriggerSignal] = []
        for f in files where f.hasSuffix(".json") {
            let p = "\(queueDir)/\(f)"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let sig = try? dec.decode(TriggerSignal.self, from: data) {
                out.append(sig)
            }
        }
        return out
    }

    func pendingCount() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: queueDir) else { return 0 }
        return files.filter { $0.hasSuffix(".json") }.count
    }
}
