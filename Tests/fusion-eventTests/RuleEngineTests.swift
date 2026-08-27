import XCTest
import os
@testable import fusion_event

private final class CountSink: TriggerSink, @unchecked Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { count.withLock { $0 } }
    func onTrigger(_ signal: TriggerSignal) async { count.withLock { $0 += 1 } }
}

final class RuleEngineTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-test-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeEngine() async -> RuleEngine {
        let store = RuleStore(dbPath: tmpDir + "rules.db", nodeId: "n1")
        let engine = RuleEngine(store: store, nodeId: "n1")
        await engine.loadFromStore()
        return engine
    }

    private func makeRule(name: String = "r1", type: SystemEventType = .fileModified, pattern: String? = "/src/*.swift", debounceMs: Int = 0, throttleMs: Int = 0, enabled: Bool = true) -> EventRule {
        EventRule(ruleName: name, eventType: type, pathPattern: pattern, debounceMs: debounceMs, throttleMs: throttleMs, targetAgent: "fusion-code", targetGraphId: nil, enabled: enabled, maxRetries: 2, requireGuard: false)
    }

    func testAddRemoveRule() async {
        let engine = await makeEngine()
        let added = await engine.addRule(makeRule())
        XCTAssertTrue(added)
        let countAfterAdd = await engine.allRules().count
        XCTAssertEqual(countAfterAdd, 1)
        let removed = await engine.removeRule("r1")
        XCTAssertTrue(removed)
        let countAfterRemove = await engine.allRules().count
        XCTAssertEqual(countAfterRemove, 0)
    }

    func testMatchByTypeAndPath() async {
        let engine = await makeEngine()
        _ = await engine.addRule(makeRule(name: "swift", pattern: "/src/*.swift"))
        _ = await engine.addRule(makeRule(name: "txt", type: .fileModified, pattern: "/src/*.txt"))
        let swiftHit = await engine.match(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1, payload: [:], rawFlags: 0))
        XCTAssertEqual(swiftHit.count, 1)
        XCTAssertEqual(swiftHit.first?.ruleName, "swift")
        let txtHit = await engine.match(RawEvent(sourceType: .fileModified, targetPath: "/src/a.txt", timestamp: 1, payload: [:], rawFlags: 0))
        XCTAssertEqual(txtHit.first?.ruleName, "txt")
        let noHit = await engine.match(RawEvent(sourceType: .processTerminated, targetPath: "/src/a.swift", timestamp: 1, payload: [:], rawFlags: 0))
        XCTAssertTrue(noHit.isEmpty)
    }

    func testDisabledRuleFilteredInProcess() async {
        let engine = await makeEngine()
        let sink = CountSink()
        await engine.setSink(sink)
        _ = await engine.addRule(makeRule(enabled: false))
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 100, payload: [:], rawFlags: 0))
        XCTAssertEqual(sink.value, 0)
    }

    func testDebounceDropsWithinWindow() async {
        let engine = await makeEngine()
        let sink = CountSink()
        await engine.setSink(sink)
        _ = await engine.addRule(makeRule(debounceMs: 200))
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1000, payload: [:], rawFlags: 0))
        await engine.flush()
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1100, payload: [:], rawFlags: 0))
        await engine.flush()
        XCTAssertEqual(sink.value, 1)
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1300, payload: [:], rawFlags: 0))
        await engine.flush()
        XCTAssertEqual(sink.value, 2)
    }

    func testThrottleDropsWithinWindow() async {
        let engine = await makeEngine()
        let sink = CountSink()
        await engine.setSink(sink)
        _ = await engine.addRule(makeRule(throttleMs: 200))
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1000, payload: [:], rawFlags: 0))
        await engine.flush()
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1100, payload: [:], rawFlags: 0))
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1150, payload: [:], rawFlags: 0))
        await engine.flush()
        XCTAssertEqual(sink.value, 1)
        await engine.process(RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1500, payload: [:], rawFlags: 0))
        await engine.flush()
        XCTAssertEqual(sink.value, 2)
    }

    func testDryRunMatchMatchesMatch() async {
        let engine = await makeEngine()
        _ = await engine.addRule(makeRule())
        let raw = RawEvent(sourceType: .fileModified, targetPath: "/src/a.swift", timestamp: 1, payload: [:], rawFlags: 0)
        let dry = await engine.dryRunMatch(raw)
        let live = await engine.match(raw)
        XCTAssertEqual(dry.count, live.count)
    }

    func testReloadPersistsAcrossInstances() async {
        let store = RuleStore(dbPath: tmpDir + "persist.db", nodeId: "n1")
        let engine1 = RuleEngine(store: store, nodeId: "n1")
        await engine1.loadFromStore()
        _ = await engine1.addRule(makeRule(name: "persisted"))
        let store2 = RuleStore(dbPath: tmpDir + "persist.db", nodeId: "n1")
        let engine2 = RuleEngine(store: store2, nodeId: "n1")
        await engine2.loadFromStore()
        let reloaded = await engine2.allRules()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.ruleName, "persisted")
    }

    func testR5RebuildDebounceWindowFromEventLog() async {
        let logPath = tmpDir + "rebuild.log"
        let eventLog = EventLog(logPath: logPath)
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let rule = makeRule(name: "rb", type: .processTerminated, pattern: "/usr/bin/*", debounceMs: 60000)
        let store1 = RuleStore(dbPath: tmpDir + "rb1.db", nodeId: "n1")
        let engine1 = RuleEngine(store: store1, nodeId: "n1")
        await engine1.setEventLog(eventLog)
        await engine1.loadFromStore()
        _ = await engine1.addRule(rule)
        let sink1 = CountSink()
        await engine1.setSink(sink1)
        await engine1.process(RawEvent(sourceType: .processTerminated, targetPath: "/usr/bin/ls", timestamp: nowMs, payload: [:], rawFlags: 0))
        await engine1.flush()
        await eventLog.recordTrigger(triggerId: "t1", taskId: nil, idempotencyKey: "k1",
            event: SystemEvent(eventId: "e1", type: .processTerminated, targetPath: "/usr/bin/ls",
                timestamp: nowMs, payload: [:], nodeId: "n1"),
            matchedRules: ["rb"])
        XCTAssertEqual(sink1.value, 1, "first event must fire")

        let store2 = RuleStore(dbPath: tmpDir + "rb2.db", nodeId: "n1")
        let engine2 = RuleEngine(store: store2, nodeId: "n1")
        await engine2.setEventLog(eventLog)
        await engine2.loadFromStore()
        _ = await engine2.addRule(rule)
        let sink2 = CountSink()
        await engine2.setSink(sink2)
        let nowMs2 = nowMs + 1000
        await engine2.process(RawEvent(sourceType: .processTerminated, targetPath: "/usr/bin/cat", timestamp: nowMs2, payload: [:], rawFlags: 0))
        XCTAssertEqual(sink2.value, 0, "R5: events.log rebuild window must suppress re-fire within debounce (60s) even when WAL lost")
    }
}
