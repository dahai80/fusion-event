import XCTest
@testable import fusion_event

final class MetricsTests: XCTestCase {

    func testCountersAccumulate() async {
        let m = MetricsCollector()
        await m.recordTriggerSubmitted()
        await m.recordTriggerSubmitted()
        await m.recordTriggerBlocked()
        await m.recordTriggerFailed()
        await m.recordTriggerDropped()
        await m.recordTriggerRetried()
        await m.recordIngestDropped(2)
        await m.recordDispatchDropped(3)
        await m.setOutboxBacklog(7)
        let snap = await m.snapshot()
        let triggers = (snap["triggers"]?.value as? [String: UInt64]) ?? [:]
        XCTAssertEqual(triggers["submitted"], 2)
        XCTAssertEqual(triggers["blocked"], 1)
        XCTAssertEqual(triggers["failed"], 1)
        XCTAssertEqual(triggers["dropped"], 1)
        XCTAssertEqual(triggers["retried"], 1)
        let drops = (snap["drops"]?.value as? [String: UInt64]) ?? [:]
        XCTAssertEqual(drops["ingest"], 2)
        XCTAssertEqual(drops["dispatch"], 3)
        XCTAssertEqual(snap["outbox_backlog"]?.value as? Int, 7)
    }

    func testLatencyHistogramPercentiles() async {
        let m = MetricsCollector()
        for ms in [1, 2, 3, 10, 50, 100, 250, 500, 1000] {
            await m.recordLatency(bridge: "guard", ms: UInt64(ms))
        }
        let snap = await m.snapshot()
        let latencyAny = snap["latency_ms"]?.value
        let latency = (latencyAny as? [String: AnyCodable]) ?? [:]
        let guardHist = (latency["guard"]?.value as? [String: UInt64]) ?? [:]
        XCTAssertEqual(guardHist["count"], 9)
        XCTAssertGreaterThanOrEqual(guardHist["p99_ms"] ?? 0, 500)
        XCTAssertLessThanOrEqual(guardHist["p50_ms"] ?? 0, 25)
        XCTAssertEqual(guardHist["max_ms"], 1000)
    }

    func testBackpressureDurationAccumulates() async {
        let m = MetricsCollector()
        let t0: UInt64 = 1000
        await m.markPressureHigh(now: t0)
        await m.markPressureNormal(now: t0 + 500)
        await m.markPressureHigh(now: t0 + 1000)
        await m.markPressureNormal(now: t0 + 1300)
        let snap = await m.snapshot()
        XCTAssertEqual(snap["backpressure_total_ms"]?.value as? UInt64, 800)
    }

    func testSnapshotIsSendableCodable() async {
        let m = MetricsCollector()
        await m.recordTriggerSubmitted()
        await m.recordLatency(bridge: "memory", ms: 42)
        let snap = await m.snapshot()
        let enc = JSONEncoder()
        let data = try? enc.encode(AnyCodable(snap))
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 10)
    }
}
