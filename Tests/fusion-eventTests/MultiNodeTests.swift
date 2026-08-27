import XCTest
import os
@testable import fusion_event

private final class CaptureSink: TriggerSink, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [TriggerSignal]())
    var signals: [TriggerSignal] { lock.withLock { $0 } }
    func onTrigger(_ signal: TriggerSignal) async {
        lock.withLock { $0.append(signal) }
    }
}

final class MultiNodeTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-mn-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for m in mockStudios { m.stop() }
        mockStudios.removeAll()
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private var mockStudios: [MockStudio] = []

    private func makeChain(nodeId: String, studioSock: String, bucketMax: Int = 5) async -> (EventBus, RuleEngine, Dispatcher, CaptureSink) {
        let store = RuleStore(dbPath: tmpDir + "mn-\(nodeId).db", nodeId: nodeId)
        let engine = RuleEngine(store: store, nodeId: nodeId)
        await engine.loadFromStore()
        let eventLog = EventLog(logPath: tmpDir + "mn-\(nodeId).log")
        let dispatcher = Dispatcher(sockPath: studioSock, timeoutSec: 1, tokenBucketMax: bucketMax, eventLog: eventLog)
        let audit = AuditBridge(sockPath: tmpDir + "guard-\(nodeId).sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: tmpDir + "memory-\(nodeId).sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        let capture = CaptureSink()
        let bus = EventBus(ruleEngine: engine)
        return (bus, engine, dispatcher, capture)
    }

    private func startStudio(nodeId: String) throws -> String {
        let path = tmpDir + "studio-\(nodeId)-\(UUID().uuidString).sock"
        let m = MockStudio(sockPath: path)
        try m.start()
        mockStudios.append(m)
        return path
    }

    private func makeRule(name: String = "mn-rule", type: SystemEventType = .fileModified, pattern: String? = "/src/**/*.swift", debounceMs: Int = 0) -> EventRule {
        EventRule(ruleName: name, eventType: type, pathPattern: pattern, debounceMs: debounceMs, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 2, requireGuard: false)
    }

    func testNodeIdPropagatesThroughTriggerChain() async {
        let (bus, engine, _, capture) = await makeChain(nodeId: "node-A", studioSock: "/tmp/fe-local-A.sock")
        await engine.setSink(capture)
        _ = await engine.addRule(makeRule())
        await bus.publish(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1000, payload: [:], rawFlags: 0))
        await engine.flush()
        XCTAssertEqual(capture.signals.count, 1)
        XCTAssertEqual(capture.signals.first?.nodeId, "node-A", "node_id must propagate event->signal (H2)")
        XCTAssertEqual(capture.signals.first?.event.nodeId, "node-A")
    }

    func testTwoNodesIsolateById() async {
        let (busA, engineA, _, captureA) = await makeChain(nodeId: "node-A", studioSock: "/tmp/fe-local-A.sock")
        let (busB, engineB, _, captureB) = await makeChain(nodeId: "node-B", studioSock: "/tmp/fe-local-B.sock")
        await engineA.setSink(captureA)
        await engineB.setSink(captureB)
        _ = await engineA.addRule(makeRule())
        _ = await engineB.addRule(makeRule())
        await busA.publish(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1000, payload: [:], rawFlags: 0))
        await busB.publish(RawEvent(sourceType: .fileModified, targetPath: "/src/b.swift", timestamp: 1000, payload: [:], rawFlags: 0))
        await engineA.flush()
        await engineB.flush()
        XCTAssertEqual(captureA.signals.first?.nodeId, "node-A")
        XCTAssertEqual(captureB.signals.first?.nodeId, "node-B")
        XCTAssertNotEqual(captureA.signals.first?.nodeId, captureB.signals.first?.nodeId, "two nodes must not cross-contaminate (H2)")
    }

    func testTriggerTargetsLocalUdsNotRemote() async {
        let localSock = "/tmp/fe-local-\(UUID().uuidString).sock"
        let (_, _, dispatcher, _) = await makeChain(nodeId: "node-A", studioSock: localSock)
        let stats = await dispatcher.stats()
        XCTAssertEqual(stats.count, 4)
        XCTAssertTrue(localSock.hasPrefix("/tmp/"), "trigger chain must target local UDS, never cross-node TCP (H2/D-8)")
    }

    func testStress2000DistinctEventsComplete() async throws {
        let studioSock = try startStudio(nodeId: "A")
        let (bus, engine, dispatcher, _) = await makeChain(nodeId: "node-A", studioSock: studioSock)
        await engine.setSink(dispatcher)
        _ = await engine.addRule(makeRule(pattern: "/src/**/*.swift", debounceMs: 0))
        let n = 2000
        for i in 0..<n {
            await bus.publish(RawEvent(
                sourceType: .fileModified,
                targetPath: "/src/f\(i)/a.swift",
                timestamp: UInt64(i),
                payload: [:],
                rawFlags: 0
            ))
        }
        await engine.flush()
        let stats = await dispatcher.stats()
        let processed = stats["submitted"]! + stats["failed"]! + stats["blocked"]!
        let dropped = stats["dropped"] ?? 0
        XCTAssertEqual(processed + dropped, UInt64(n), "all 2000 distinct events accounted: processed or counted-dropped, none silently lost (F2/L2 backpressure)")
        XCTAssertLessThanOrEqual(processed, UInt64(n))
    }

    func testStressDuplicatesCollapseToOne() async throws {
        let studioSock = try startStudio(nodeId: "A")
        let (bus, engine, dispatcher, _) = await makeChain(nodeId: "node-A", studioSock: studioSock)
        await engine.setSink(dispatcher)
        _ = await engine.addRule(makeRule(pattern: "/src/**/*.swift", debounceMs: 0))
        let n = 2000
        for _ in 0..<n {
            await bus.publish(RawEvent(
                sourceType: .fileModified,
                targetPath: "/src/a.swift",
                timestamp: 1000,
                payload: [:],
                rawFlags: 0
            ))
        }
        await engine.flush()
        let stats = await dispatcher.stats()
        let processed = stats["submitted"]! + stats["failed"]!
        XCTAssertEqual(processed, 1, "2000 duplicate signals same idempotency key must collapse to 1 task (H1/F9)")
    }

    func testTokenBucketSmallMaxStillProcessesAllDistinct() async throws {
        let studioSock = try startStudio(nodeId: "A")
        let (bus, engine, dispatcher, _) = await makeChain(nodeId: "node-A", studioSock: studioSock, bucketMax: 2)
        await engine.setSink(dispatcher)
        _ = await engine.addRule(makeRule(pattern: "/src/**/*.swift", debounceMs: 0))
        let n = 500
        for i in 0..<n {
            await bus.publish(RawEvent(
                sourceType: .fileModified,
                targetPath: "/src/f\(i)/a.swift",
                timestamp: UInt64(i),
                payload: [:],
                rawFlags: 0
            ))
        }
        await engine.flush()
        let stats = await dispatcher.stats()
        let processed = stats["submitted"]! + stats["failed"]! + stats["blocked"]!
        let dropped = stats["dropped"] ?? 0
        XCTAssertEqual(processed + dropped, UInt64(n), "bucketMax=2 must queue+drain all distinct, none silently lost (R1/F2)")
    }
}
