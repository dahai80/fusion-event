import XCTest
@testable import fusion_event

final class DispatcherTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-disp-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeDispatcher(bucketMax: Int = 5) -> Dispatcher {
        let eventLog = EventLog(logPath: tmpDir + "event.log")
        return Dispatcher(sockPath: "/tmp/fe-nonexistent-\(UUID().uuidString).sock", timeoutSec: 1, tokenBucketMax: bucketMax, eventLog: eventLog)
    }

    private func makeSignal(requireGuard: Bool = false) -> TriggerSignal {
        let rule = EventRule(ruleName: "r1", eventType: .fileModified, pathPattern: "/x/*", debounceMs: 200, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 2, requireGuard: requireGuard)
        let raw = RawEvent(sourceType: .fileModified, targetPath: "/x/a.swift", timestamp: 1000, payload: [:], rawFlags: 0)
        return Normalizer.normalize(event: raw, rule: rule, nodeId: "n1")
    }

    func testIdempotencySuppressesDuplicateKey() async {
        let dispatcher = makeDispatcher()
        let audit = AuditBridge(sockPath: "/tmp/fe-noaudit-\(UUID().uuidString).sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: "/tmp/fe-nomem-\(UUID().uuidString).sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        let signal = makeSignal()
        await dispatcher.onTrigger(signal)
        await dispatcher.onTrigger(signal)
        let stats = await dispatcher.stats()
        XCTAssertLessThanOrEqual(stats["submitted"]! + stats["failed"]!, 1)
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
        XCTAssertEqual(stats.count, 3)
        XCTAssertNotNil(stats["submitted"])
        XCTAssertNotNil(stats["blocked"])
        XCTAssertNotNil(stats["failed"])
    }
}
