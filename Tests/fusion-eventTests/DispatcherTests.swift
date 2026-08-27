import XCTest
@testable import fusion_event

final class DispatcherTests: XCTestCase {
    private var tmpDir: String = ""
    private var mock: MockStudio?

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-disp-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        mock?.stop()
        mock = nil
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeDispatcher(bucketMax: Int = 5, sockPath: String? = nil) -> Dispatcher {
        let eventLog = EventLog(logPath: tmpDir + "event.log")
        let path = sockPath ?? "/tmp/fe-nonexistent-\(UUID().uuidString).sock"
        return Dispatcher(sockPath: path, timeoutSec: 1, tokenBucketMax: bucketMax, queueMax: 512, eventLog: eventLog, outboxDir: tmpDir + "outbox")
    }

    private func startMockStudio() throws -> String {
        let path = tmpDir + "studio.sock"
        let m = MockStudio(sockPath: path)
        try m.start()
        mock = m
        return path
    }

    private func makeSignal(requireGuard: Bool = false) -> TriggerSignal {
        let rule = EventRule(ruleName: "r1", eventType: .fileModified, pathPattern: "/x/*", debounceMs: 200, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 2, requireGuard: requireGuard)
        let raw = RawEvent(sourceType: .fileModified, targetPath: "/x/a.swift", timestamp: 1000, payload: [:], rawFlags: 0)
        return Normalizer.normalize(event: raw, rule: rule, nodeId: "n1")
    }

    func testIdempotencySuppressesDuplicateKey() async throws {
        let studioPath = try startMockStudio()
        let dispatcher = makeDispatcher(sockPath: studioPath)
        let audit = AuditBridge(sockPath: "/tmp/fe-noaudit-\(UUID().uuidString).sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: "/tmp/fe-nomem-\(UUID().uuidString).sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        let signal = makeSignal()
        await dispatcher.onTrigger(signal)
        await dispatcher.onTrigger(signal)
        let stats = await dispatcher.stats()
        XCTAssertEqual(stats["submitted"], 1, "first task.submit succeeds, occupies idempotency key (F9)")
        XCTAssertEqual(stats["failed"], 0)
        XCTAssertEqual(stats["blocked"], 0)
    }

    func testRequireGuardFailClosedCountsBlocked() async {
        let dispatcher = makeDispatcher()
        let audit = AuditBridge(sockPath: "/tmp/fe-noaudit-\(UUID().uuidString).sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: "/tmp/fe-nomem-\(UUID().uuidString).sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        let signal = makeSignal(requireGuard: true)
        await dispatcher.onTrigger(signal)
        let stats = await dispatcher.stats()
        XCTAssertEqual(stats["blocked"], 1)
    }

    func testStatsShape() async {
        let dispatcher = makeDispatcher()
        let stats = await dispatcher.stats()
        XCTAssertEqual(stats.count, 5)
        XCTAssertNotNil(stats["submitted"])
        XCTAssertNotNil(stats["blocked"])
        XCTAssertNotNil(stats["failed"])
        XCTAssertNotNil(stats["dropped"])
        XCTAssertNotNil(stats["retried"])
    }
}
