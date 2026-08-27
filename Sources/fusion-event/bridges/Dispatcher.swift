import Foundation

public actor Dispatcher: TriggerSink {
    private let sockPath: String
    private let timeoutSec: Int
    private let tokenBucketMax: Int
    private var availableTokens: Int
    private var pendingQueue: [TriggerSignal] = []
    private var recentKeys: [String: (taskId: String, expiryTs: UInt64)] = [:]
    private var recentKeyOrder: [String] = []
    private let keyTtlMs: UInt64 = 60_000
    private let keyMaxEntries: Int = 10_000
    private let queueMax: Int = 50
    private var client: UDSClient?
    private var auditBridge: AuditBridge?
    private var contextBridge: ContextBridge?
    private let eventLog: EventLog
    private var submittedCount: UInt64 = 0
    private var blockedCount: UInt64 = 0
    private var failedCount: UInt64 = 0
    private var droppedCount: UInt64 = 0
    private var shuttingDown = false

    init(
        sockPath: String,
        timeoutSec: Int,
        tokenBucketMax: Int,
        eventLog: EventLog
    ) {
        self.sockPath = sockPath
        self.timeoutSec = timeoutSec
        self.tokenBucketMax = tokenBucketMax
        self.availableTokens = tokenBucketMax
        self.eventLog = eventLog
    }

    public func setBridges(audit: AuditBridge, context: ContextBridge) {
        self.auditBridge = audit
        self.contextBridge = context
    }

    public func onTrigger(_ signal: TriggerSignal) async {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
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
                FusionLog.bridge.error("trigger queue overflow (max \(self.queueMax)), drop oldest \(dropped.triggerId, privacy: .public)")
            }
            pendingQueue.append(signal)
            FusionLog.bridge.notice("trigger queue backlog, \(self.pendingQueue.count, privacy: .public) waiting (R1)")
        }
    }

    private func drainQueue(now: UInt64) async {
        guard !pendingQueue.isEmpty, availableTokens > 0, !shuttingDown else { return }
        let next = pendingQueue.removeFirst()
        availableTokens -= 1
        await runTriggerChain(signal: next, now: now)
        availableTokens += 1
        await drainQueue(now: now)
    }

    private func runTriggerChain(signal: TriggerSignal, now: UInt64) async {
        guard let audit = auditBridge else {
            FusionLog.bridge.error("auditBridge nil, skip \(signal.triggerId)")
            return
        }
        let outcome = await audit.audit(signal: signal)
        switch outcome {
        case .block(let res):
            blockedCount += 1
            FusionLog.bridge.notice("guard block \(signal.triggerId, privacy: .public): \(res.reason)")
            occupyKey(signal.idempotencyKey, taskId: "blocked", now: now)
            await eventLog.recordTrigger(
                triggerId: signal.triggerId, taskId: nil,
                idempotencyKey: signal.idempotencyKey, event: signal.event,
                matchedRules: [signal.rule.ruleName]
            )
            return
        case .failClosed(let reason):
            blockedCount += 1
            FusionLog.bridge.error("fail-closed \(signal.triggerId, privacy: .public): \(reason)")
            occupyKey(signal.idempotencyKey, taskId: "failclosed", now: now)
            await eventLog.recordTrigger(
                triggerId: signal.triggerId, taskId: nil,
                idempotencyKey: signal.idempotencyKey, event: signal.event,
                matchedRules: [signal.rule.ruleName]
            )
            return
        case .pass, .degradedFailOpen, .challenge:
            break
        }
        let ctx = await contextBridge?.retrieveContext(signal: signal) ?? ContextResult(context: "", memoryIds: [], cacheHit: false, contextStale: false)
        await submitTask(signal: signal, context: ctx, now: now)
    }

    private func submitTask(signal: TriggerSignal, context: ContextResult, now: UInt64) async {
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
        do {
            let resp = try await callWithTimeout(req)
            var taskId: String? = nil
            if let res = resp.result?.value as? [String: Any], let task = res["task"] as? [String: Any] {
                taskId = task["task_id"] as? String
            }
            occupyKey(signal.idempotencyKey, taskId: taskId ?? "unknown", now: now)
            submittedCount += 1
            FusionLog.bridge.info("task.submit ok trigger=\(signal.triggerId, privacy: .public) task=\(taskId ?? "?") idem=\(signal.idempotencyKey, privacy: .public)")
            await eventLog.recordTrigger(
                triggerId: signal.triggerId, taskId: taskId,
                idempotencyKey: signal.idempotencyKey, event: signal.event,
                matchedRules: [signal.rule.ruleName]
            )
        } catch let err as UDSClientError {
            failedCount += 1
            await resetClient()
            switch err {
            case .connectionFailed:
                FusionLog.bridge.error("task.submit fail agent-studio not running, no retry (R3) trigger=\(signal.triggerId)")
            case .timeout:
                FusionLog.bridge.error("task.submit timeout, no retry (R3) trigger=\(signal.triggerId)")
            default:
                FusionLog.bridge.error("task.submit io error, no retry trigger=\(signal.triggerId)")
            }
            await eventLog.recordTrigger(
                triggerId: signal.triggerId, taskId: nil,
                idempotencyKey: signal.idempotencyKey, event: signal.event,
                matchedRules: [signal.rule.ruleName]
            )
        } catch {
            failedCount += 1
            FusionLog.bridge.error("task.submit unknown error, no retry trigger=\(signal.triggerId)")
        }
    }

    private func eventDict(_ e: SystemEvent) -> [String: Any] {
        [
            "eventId": e.eventId,
            "type": e.type.rawValue,
            "targetPath": e.targetPath ?? "",
            "timestamp": e.timestamp,
            "payload": e.payload,
            "nodeId": e.nodeId
        ]
    }

    private func occupyKey(_ key: String, taskId: String, now: UInt64) {
        if recentKeys[key] == nil {
            recentKeyOrder.append(key)
        }
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
        for k in expired {
            recentKeys.removeValue(forKey: k)
            recentKeyOrder.removeAll { $0 == k }
        }
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
        let c = UDSClient(sockPath: sockPath)
        client = c
        return c
    }

    public func drainForShutdown() async {
        shuttingDown = true
        let pending = pendingQueue
        pendingQueue.removeAll()
        if !pending.isEmpty {
            FusionLog.bridge.notice("shutdown drain: drop \(pending.count) pending triggers (logged, no submit)")
            for sig in pending {
                await eventLog.recordTrigger(
                    triggerId: sig.triggerId, taskId: nil,
                    idempotencyKey: sig.idempotencyKey, event: sig.event,
                    matchedRules: [sig.rule.ruleName]
                )
            }
        }
        await client?.close()
        client = nil
    }

    public func stats() -> [String: UInt64] {
        ["submitted": submittedCount, "blocked": blockedCount, "failed": failedCount, "dropped": droppedCount]
    }
}
