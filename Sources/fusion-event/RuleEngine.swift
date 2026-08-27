import Foundation

public actor RuleEngine {
    private var rules: [EventRule] = []
    private var debounceState: [String: UInt64] = [:]
    private var throttleState: [String: [UInt64]] = [:]
    private let store: RuleStore
    private weak var sink: TriggerSink?
    private let nodeId: String
    private var eventLog: EventLog?

    init(store: RuleStore, nodeId: String) {
        self.store = store
        self.nodeId = nodeId
    }

    public func setSink(_ sink: TriggerSink) {
        self.sink = sink
    }

    func setEventLog(_ log: EventLog) {
        self.eventLog = log
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
        for rule in matched {
            if !rule.enabled { continue }
            if !checkDebounce(rule: rule, now: now) { continue }
            if !checkThrottle(rule: rule, now: now) { continue }
            updateDebounce(rule: rule, now: now)
            await store.saveDebounceState(ruleName: rule.ruleName, lastFireTs: now)
            let signal = Normalizer.normalize(event: event, rule: rule, nodeId: nodeId)
            FusionLog.rule.info("rule hit \(rule.ruleName, privacy: .public) trigger=\(signal.triggerId, privacy: .public) idem=\(signal.idempotencyKey, privacy: .public)")
            await sink?.onTrigger(signal)
        }
    }

    public func match(_ event: RawEvent) -> [EventRule] {
        self.rules.filter { rule in
            rule.eventType == event.sourceType &&
            Glob.match(pattern: rule.pathPattern, path: event.targetPath ?? "")
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
        if !stamps.isEmpty {
            FusionLog.rule.debug("throttle drop \(rule.ruleName, privacy: .public)")
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
