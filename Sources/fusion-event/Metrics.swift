import Foundation

public actor MetricsCollector {
    private var sourceEventCount: [String: UInt64] = [:]
    private var triggerSubmitted: UInt64 = 0
    private var triggerBlocked: UInt64 = 0
    private var triggerFailed: UInt64 = 0
    private var triggerDropped: UInt64 = 0
    private var triggerRetried: UInt64 = 0
    private var ingestDropped: UInt64 = 0
    private var dispatchDropped: UInt64 = 0
    private var outboxBacklog: Int = 0
    private var pressureHighSince: UInt64?
    private var pressureTotalMs: UInt64 = 0

    private var latencyBuckets: [String: LatencyHistogram] = [:]

    private let startedAt: UInt64

    init() {
        self.startedAt = UInt64(Date().timeIntervalSince1970 * 1000)
    }

    func recordSourceEvent(_ type: String) {
        sourceEventCount[type, default: 0] += 1
    }

    func recordTriggerSubmitted() { triggerSubmitted += 1 }
    func recordTriggerBlocked() { triggerBlocked += 1 }
    func recordTriggerFailed() { triggerFailed += 1 }
    func recordTriggerDropped() { triggerDropped += 1 }
    func recordTriggerRetried() { triggerRetried += 1 }
    func recordIngestDropped(_ n: UInt64 = 1) { ingestDropped += n }
    func recordDispatchDropped(_ n: UInt64 = 1) { dispatchDropped += n }
    func setOutboxBacklog(_ n: Int) { outboxBacklog = n }

    func recordLatency(bridge: String, ms: UInt64) {
        if latencyBuckets[bridge] == nil {
            latencyBuckets[bridge] = LatencyHistogram()
        }
        latencyBuckets[bridge]!.record(ms)
    }

    func markPressureHigh(now: UInt64) {
        if pressureHighSince == nil {
            pressureHighSince = now
            FusionLog.metrics.notice("metrics backpressure HIGH start (O1)")
        }
    }

    func markPressureNormal(now: UInt64) {
        if let start = pressureHighSince {
            let dur = now > start ? now - start : 0
            pressureTotalMs += dur
            pressureHighSince = nil
            FusionLog.metrics.notice("metrics backpressure NORMAL, duration=\(dur)ms total=\(self.pressureTotalMs)ms (O1)")
        }
    }

    func snapshot() -> [String: AnyCodable] {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var latency: [String: AnyCodable] = [:]
        for (bridge, hist) in latencyBuckets {
            latency[bridge] = AnyCodable(hist.summary())
        }
        let pressureActiveMs = pressureHighSince.map { now > $0 ? now - $0 : 0 } ?? 0
        return [
            "uptime_ms": AnyCodable(now - startedAt),
            "source_events": AnyCodable(sourceEventCount),
            "triggers": AnyCodable([
                "submitted": triggerSubmitted,
                "blocked": triggerBlocked,
                "failed": triggerFailed,
                "dropped": triggerDropped,
                "retried": triggerRetried
            ] as [String: UInt64]),
            "drops": AnyCodable([
                "ingest": ingestDropped,
                "dispatch": dispatchDropped
            ] as [String: UInt64]),
            "outbox_backlog": AnyCodable(outboxBacklog),
            "backpressure_total_ms": AnyCodable(pressureTotalMs),
            "backpressure_active_ms": AnyCodable(pressureActiveMs),
            "backpressure_active": AnyCodable(pressureHighSince != nil),
            "latency_ms": AnyCodable(latency)
        ]
    }
}

final class LatencyHistogram: @unchecked Sendable {
    private let buckets: [UInt64] = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000]
    private var counts: [UInt64]
    private var totalSamples: UInt64 = 0
    private var totalMs: UInt64 = 0
    private var maxMs: UInt64 = 0

    init() {
        self.counts = Array(repeating: 0, count: buckets.count + 1)
    }

    func record(_ ms: UInt64) {
        totalSamples += 1
        totalMs += ms
        if ms > maxMs { maxMs = ms }
        for i in 0..<buckets.count {
            if ms <= buckets[i] {
                counts[i] += 1
                return
            }
        }
        counts[buckets.count] += 1
    }

    func summary() -> [String: UInt64] {
        let avg = totalSamples > 0 ? totalMs / totalSamples : 0
        let p99 = percentile(0.99)
        let p50 = percentile(0.50)
        return [
            "count": totalSamples,
            "avg_ms": avg,
            "p50_ms": p50,
            "p99_ms": p99,
            "max_ms": maxMs
        ]
    }

    private func percentile(_ p: Double) -> UInt64 {
        guard totalSamples > 0 else { return 0 }
        let target = UInt64(Double(totalSamples) * p)
        var cum: UInt64 = 0
        for i in 0..<counts.count {
            cum += counts[i]
            if cum >= target {
                if i < buckets.count {
                    return buckets[i]
                }
                return maxMs
            }
        }
        return maxMs
    }
}
