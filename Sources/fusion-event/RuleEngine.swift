import Foundation

public actor RuleEngine {
    private var rules: [EventRule] = []
    private var debounceState: [String: UInt64] = [:]
    private var throttleState: [String: [UInt64]] = [:]
    private let store: RuleStore
    private weak var sink: TriggerSink?
    private let nodeId: String
    private var eventLog: EventLog?
    private var dispatchStream: AsyncStream<TriggerSignal>.Continuation?
    private var dispatchStreamId: UUID?
    private var droppedCount: UInt64 = 0
    private var pendingDispatch: Int = 0
    private var monotonicHighWater: UInt64 = 0
    private var dbWriteQueue: [(ruleName: String, lastFireTs: UInt64)] = []
    private var dbWriteTask: Task<Void, Never>?
    private let dbBatchSize: Int = 64

    init(store: RuleStore, nodeId: String) {
        self.store = store
        self.nodeId = nodeId
    }

    public func setSink(_ sink: TriggerSink) {
        self.sink = sink
        startDispatchLoop()
    }

    func setEventLog(_ log: EventLog) {
        self.eventLog = log
    }

    private func startDispatchLoop() {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: TriggerSignal.self, bufferingPolicy: .bufferingNewest(8192))
        cont.onTermination = { [weak self] _ in
            Task { await self?.clearDispatchStream() }
        }
        dispatchStream = cont
        dispatchStreamId = id
        let sinkRef = sink
        Task { [weak self] in
            for await signal in stream {
                await sinkRef?.onTrigger(signal)
                await self?.dispatchDrained()
                await self?.maybeStartDbFlush()
            }
        }
        FusionLog.rule.info("ruleengine dispatch loop start, backpressure buffer 8192 (F2)")
    }

    private func dispatchDrained() {
        pendingDispatch = max(0, pendingDispatch - 1)
    }

    public func flush() async {
        while pendingDispatch > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func clearDispatchStream() {
        if dispatchStreamId != nil {
            dispatchStream = nil
            dispatchStreamId = nil
        }
    }

    public func loadFromStore() async {
        rules = await store.loadAll()
        debounceState = await store.loadDebounceState()
        if let eventLog {
            let window = await eventLog.recentDebounceWindow(withinSec: 60)
            var merged = 0
            for (ruleName, ts) in window {
                if (debounceState[ruleName] ?? 0) < ts {
                    debounceState[ruleName] = ts
                    merged += 1
                }
            }
            if merged > 0 {
                FusionLog.rule.info("ruleengine rebuild debounce window from events.log, merged \(merged, privacy: .public) rules (R5 双保险)")
            }
        }
        FusionLog.rule.info("ruleengine loaded \(self.rules.count, privacy: .public) rules, \(self.debounceState.count, privacy: .public) debounce states")
    }

    public func allRules() -> [EventRule] { rules }

    public func addRule(_ rule: EventRule) async -> Bool {
        let ok = await store.upsert(rule)
        if ok {
            if let idx = rules.firstIndex(where: { $0.ruleName == rule.ruleName }) {
                rules[idx] = rule
            } else {
                rules.append(rule)
            }
            FusionLog.rule.info("rule add \(rule.ruleName, privacy: .public), total \(self.rules.count, privacy: .public)")
        }
        return ok
    }

    public func removeRule(_ name: String) async -> Bool {
        let ok = await store.remove(name)
        if ok {
            rules.removeAll(where: { $0.ruleName == name })
            debounceState.removeValue(forKey: name)
            throttleState.removeValue(forKey: name)
            FusionLog.rule.info("rule remove \(name, privacy: .public), total \(self.rules.count, privacy: .public)")
        }
        return ok
    }

    public func reload() async {
        await loadFromStore()
    }

    public func process(_ event: RawEvent) async {
        let matched = match(event)
        guard !matched.isEmpty else { return }
        let now = event.timestamp
        if now > monotonicHighWater {
            monotonicHighWater = now
        } else if now < monotonicHighWater {
            let clamped = monotonicHighWater + 1
            monotonicHighWater = clamped
            FusionLog.rule.notice("clock rollback detected wall=\(now) < hwm=\(self.monotonicHighWater - 1), clamped to \(clamped) (A6/R3: monotonic dedup guard)")
        }
        let monotonicNow = monotonicHighWater
        for rule in matched {
            if !rule.enabled { continue }
            if !checkDebounce(rule: rule, now: monotonicNow) { continue }
            if !checkThrottle(rule: rule, now: monotonicNow) { continue }
            updateDebounce(rule: rule, now: monotonicNow)
            dbWriteQueue.append((rule.ruleName, monotonicNow))
            let signal = Normalizer.normalize(event: event, rule: rule, nodeId: nodeId, dedupTs: monotonicNow)
            FusionLog.rule.info("rule hit \(rule.ruleName, privacy: .public) trigger=\(signal.triggerId, privacy: .public) idem=\(signal.idempotencyKey, privacy: .public)")
            guard let cont = dispatchStream else {
                droppedCount += 1
                FusionLog.rule.error("dispatch stream nil, drop trigger=\(signal.triggerId, privacy: .public) (F2)")
                continue
            }
            let yielded = cont.yield(signal)
            switch yielded {
            case .terminated:
                droppedCount += 1
                FusionLog.rule.error("dispatch stream terminated, drop trigger=\(signal.triggerId, privacy: .public) (F2)")
            case .dropped:
                droppedCount += 1
                pendingDispatch = max(0, pendingDispatch - 1)
                FusionLog.rule.error("dispatch queue full (backpressure), drop oldest trigger=\(signal.triggerId, privacy: .public) (F2)")
            default:
                pendingDispatch += 1
            }
        }
    }

    private func maybeStartDbFlush() async {
        guard dbWriteTask == nil, !dbWriteQueue.isEmpty else { return }
        let batch = Array(dbWriteQueue.prefix(dbBatchSize))
        dbWriteQueue.removeFirst(min(dbWriteQueue.count, dbBatchSize))
        dbWriteTask = Task { [weak self] in
            for (ruleName, ts) in batch {
                await self?.store.saveDebounceState(ruleName: ruleName, lastFireTs: ts)
            }
            await self?.finishDbFlush()
        }
    }

    private func finishDbFlush() {
        dbWriteTask = nil
    }

    public func dispatchDroppedCount() -> UInt64 { droppedCount }

    public func match(_ event: RawEvent) -> [EventRule] {
        self.rules.filter { rule in
            rule.eventType == event.sourceType && Glob.match(pattern: rule.pathPattern, path: event.targetPath ?? "")
        }
    }

    public func dryRunMatch(_ event: RawEvent) -> [EventRule] {
        match(event)
    }

    private func checkDebounce(rule: EventRule, now: UInt64) -> Bool {
        guard rule.debounceMs > 0 else { return true }
        if let last = debounceState[rule.ruleName] {
            let window = UInt64(rule.debounceMs)
            if now - last < window {
                FusionLog.rule.debug("debounce drop \(rule.ruleName, privacy: .public) delta=\(now - last)")
                return false
            }
        }
        return true
    }

    private func checkThrottle(rule: EventRule, now: UInt64) -> Bool {
        guard rule.throttleMs > 0 else { return true }
        var stamps = throttleState[rule.ruleName] ?? []
        let window = UInt64(rule.throttleMs)
        stamps = stamps.filter { now - $0 < window }
        if stamps.count >= rule.throttleMaxPerWindow {
            FusionLog.rule.debug("throttle drop \(rule.ruleName, privacy: .public) count=\(stamps.count)/\(rule.throttleMaxPerWindow)")
            throttleState[rule.ruleName] = stamps
            return false
        }
        throttleState[rule.ruleName] = stamps
        return true
    }

    private func updateDebounce(rule: EventRule, now: UInt64) {
        debounceState[rule.ruleName] = now
        if rule.throttleMs > 0 {
            var stamps = throttleState[rule.ruleName] ?? []
            stamps.append(now)
            throttleState[rule.ruleName] = stamps
        }
    }
}

public protocol TriggerSink: AnyObject, Sendable {
    func onTrigger(_ signal: TriggerSignal) async
}
