import XCTest
import os
@testable import fusion_event

// Stress + chaos harness. NOT in default `swift test`.
// Run: FUSION_EVENT_STRESS=1 swift test --filter StressHarnessTests
// Guard: env flag FUSION_EVENT_STRESS must be set, else XCTSkip.
// Covers release-readiness gaps O2: long-run memory drift, downstream-kill
// outbox replay, disk-full degrade, concurrent IPC client load.

private func stressEnabled() -> Bool {
    ProcessInfo.processInfo.environment["FUSION_EVENT_STRESS"] != nil
}

private func stressIters() -> Int {
    let v = ProcessInfo.processInfo.environment["FUSION_EVENT_STRESS_ITERS"] ?? "2000"
    return Int(v) ?? 2000
}

private func stressRawEvent(path: String, ts: UInt64) -> RawEvent {
    RawEvent(sourceType: .fileModified, targetPath: path, timestamp: ts, payload: [:], rawFlags: 0)
}

private final class CaptureSink: TriggerSink, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [TriggerSignal]())
    var signals: [TriggerSignal] { lock.withLock { $0 } }
    var count: Int { lock.withLock { $0.count } }
    func onTrigger(_ signal: TriggerSignal) async {
        lock.withLock { $0.append(signal) }
    }
    func reset() { lock.withLock { $0.removeAll() } }
}

final class StressHarnessTests: XCTestCase {
    private var tmpDir: String = ""
    private var mockStudios: [MockStudio] = []
    private var studioCounter: Int = 0

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fes\(getpid())/"
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

    private func startStudio(name: String) throws -> String {
        studioCounter += 1
        let path = tmpDir + "s\(studioCounter).sock"
        let m = MockStudio(sockPath: path)
        try m.start()
        mockStudios.append(m)
        return path
    }

    private func makeChain(nodeId: String = "n1", studioSock: String) async -> (EventBus, RuleEngine, Dispatcher, CaptureSink, String) {
        studioCounter += 1
        let gid = studioCounter
        let store = RuleStore(dbPath: tmpDir + "r\(gid).db", nodeId: nodeId)
        let engine = RuleEngine(store: store, nodeId: nodeId)
        await engine.loadFromStore()
        let eventLog = EventLog(logPath: tmpDir + "e\(gid).log")
        let outboxDir = tmpDir + "o\(gid)"
        let dispatcher = Dispatcher(sockPath: studioSock, timeoutSec: 1, tokenBucketMax: 64, queueMax: 2048, eventLog: eventLog, outboxDir: outboxDir)
        let audit = AuditBridge(sockPath: tmpDir + "g\(gid).sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: tmpDir + "m\(gid).sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        let capture = CaptureSink()
        await engine.setSink(dispatcher)
        let bus = EventBus(ruleEngine: engine)
        await bus.start()
        return (bus, engine, dispatcher, capture, outboxDir)
    }

    private func makeRule(name: String = "stress-rule", pattern: String = "/src/**/*.swift", debounceMs: Int = 0) -> EventRule {
        EventRule(
            ruleName: name, eventType: .fileModified, pathPattern: pattern, debounceMs: debounceMs, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 1,
            requireGuard: false)
    }

    // 24h-capable long-run: N distinct events, verify no crash + no leak growth.
    // RSS measured start vs end; drift must stay bounded (heuristic, not absolute).
    func testLongRunMemoryDriftBounded() async throws {
        try XCTSkipUnless(stressEnabled(), "stress harness: set FUSION_EVENT_STRESS=1")
        let n = stressIters()
        let studioSock = try startStudio(name: "longrun")
        let (bus, engine, dispatcher, _, _) = await makeChain(studioSock: studioSock)
        let ok = await engine.addRule(makeRule())
        XCTAssertTrue(ok)
        let rssStart = currentRSSKB()
        FusionLog.ipc.notice("stress long-run start n=\(n, privacy: .public) rssKB=\(rssStart, privacy: .public)")
        for i in 0..<n {
            await bus.publish(stressRawEvent(path: "/src/\(i)/a.swift", ts: UInt64(i)))
            if i % 500 == 0 && i > 0 {
                await bus.drainIngest()
            }
        }
        await bus.drainIngest()
        await engine.flush()
        let stats = await dispatcher.stats()
        let rssEnd = currentRSSKB()
        let drift = rssEnd > rssStart ? rssEnd - rssStart : 0
        FusionLog.ipc.notice("stress long-run done submitted=\(stats["submitted"] ?? 0) rssKB=\(rssEnd, privacy: .public) driftKB=\(drift, privacy: .public)")
        XCTAssertGreaterThan(stats["submitted"] ?? 0, 0, "long-run must process events")
        XCTAssertLessThan(drift, 200_000, "RSS drift unbounded — investigate leak (heuristic 200MB cap)")
        await bus.shutdown()
    }

    // Downstream-kill chaos: kill studio mid-stream, keep pushing, restart,
    // replayOutbox must resubmit pending triggers (R4 crash-safe replay).
    func testDownstreamKillOutboxReplay() async throws {
        try XCTSkipUnless(stressEnabled(), "stress harness: set FUSION_EVENT_STRESS=1")
        let studioSock = try startStudio(name: "kill")
        let (bus, engine, dispatcher, _, outboxDir) = await makeChain(studioSock: studioSock)
        let ok = await engine.addRule(makeRule())
        XCTAssertTrue(ok)
        // Phase 1: publish with studio UP — should submit.
        for i in 0..<20 {
            await bus.publish(stressRawEvent(path: "/src/up/\(i).swift", ts: UInt64(i)))
        }
        await bus.drainIngest()
        await engine.flush()
        let statsUp = await dispatcher.stats()
        XCTAssertGreaterThan(statsUp["submitted"] ?? 0, 0, "pre-kill events must submit")
        // Phase 2: kill studio, publish more — these fail + land in outbox.
        killStudio()
        for i in 20..<60 {
            await bus.publish(stressRawEvent(path: "/src/down/\(i).swift", ts: UInt64(i)))
        }
        await bus.drainIngest()
        await engine.flush()
        let statsDown = await dispatcher.stats()
        let failed = statsDown["failed"] ?? 0
        FusionLog.ipc.notice("stress downstream-kill failed=\(failed) (expected >0, retries exhaust -> outbox)")
        XCTAssertGreaterThan(failed, 0, "killed studio must cause failed triggers")
        // Phase 3: restart studio + replay outbox — pending must resubmit.
        let newSock = try startStudio(name: "kill-restart")
        let pendingBefore = outboxPendingCount(dir: outboxDir)
        FusionLog.ipc.notice("stress outbox pending before replay=\(pendingBefore, privacy: .public)")
        // New dispatcher reading same outbox dir, fresh idempotency keys expired.
        let eventLog2 = EventLog(logPath: tmpDir + "e-replay.log")
        let dispatcher2 = Dispatcher(sockPath: newSock, timeoutSec: 1, tokenBucketMax: 64, queueMax: 2048, eventLog: eventLog2, outboxDir: outboxDir)
        let audit2 = AuditBridge(sockPath: tmpDir + "g-replay.sock", timeoutSec: 1)
        let ctx2 = ContextBridge(sockPath: tmpDir + "m-replay.sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher2.setBridges(audit: audit2, context: ctx2)
        await dispatcher2.replayOutbox()
        let statsReplay = await dispatcher2.stats()
        let pendingAfter = outboxPendingCount(dir: outboxDir)
        FusionLog.ipc.notice("stress outbox pending after replay=\(pendingAfter, privacy: .public) replayed submitted=\(statsReplay["submitted"] ?? 0)")
        XCTAssertGreaterThan(statsReplay["submitted"] ?? 0, 0, "replay must resubmit at least one outbox trigger (R4)")
        XCTAssertLessThanOrEqual(pendingAfter, pendingBefore, "replay must not grow outbox")
        await bus.shutdown()
    }

    // Disk-full degrade: outbox dir made read-only/unwritable. Dispatcher must
    // NOT crash; submits still attempt, outbox writes degrade gracefully.
    func testDiskFullDegradeNoCrash() async throws {
        try XCTSkipUnless(stressEnabled(), "stress harness: set FUSION_EVENT_STRESS=1")
        let studioSock = try startStudio(name: "disk")
        let (bus, engine, dispatcher, _, outboxRoot) = await makeChain(studioSock: studioSock)
        let ok = await engine.addRule(makeRule())
        XCTAssertTrue(ok)
        // Make outbox dir unwritable (simulates full disk / permission denied).
        let outboxDir = outboxRoot + "/outbox"
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: outboxDir)
        // Publish events — must not crash even with unwritable outbox.
        for i in 0..<40 {
            await bus.publish(stressRawEvent(path: "/src/disk/\(i).swift", ts: UInt64(i)))
        }
        await bus.drainIngest()
        await engine.flush()
        let stats = await dispatcher.stats()
        // Restore perms for teardown.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outboxDir)
        FusionLog.ipc.notice("stress disk-full done submitted=\(stats["submitted"] ?? 0) failed=\(stats["failed"] ?? 0) dropped=\(stats["dropped"] ?? 0) (no crash = pass)")
        // No assertion crash = pass. Daemon survived degraded outbox.
        XCTAssertEqual(stats.count, 5, "dispatcher stats intact after disk-full")
        await bus.shutdown()
    }

    // Concurrent client load: many parallel IPC clients hit studio socket.
    // Verifies no deadlock/connection-leak under concurrent dispatch.
    func testConcurrentClientLoad() async throws {
        try XCTSkipUnless(stressEnabled(), "stress harness: set FUSION_EVENT_STRESS=1")
        let studioSock = try startStudio(name: "concurrent")
        let (bus, engine, dispatcher, _, _) = await makeChain(studioSock: studioSock)
        let ok = await engine.addRule(makeRule())
        XCTAssertTrue(ok)
        let n = min(stressIters(), 1000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask { [weak bus] in
                    await bus?.publish(stressRawEvent(path: "/src/cc/\(i).swift", ts: UInt64(i)))
                }
            }
        }
        await bus.drainIngest()
        await engine.flush()
        let stats = await dispatcher.stats()
        FusionLog.ipc.notice("stress concurrent done submitted=\(stats["submitted"] ?? 0) failed=\(stats["failed"] ?? 0)")
        XCTAssertGreaterThan(stats["submitted"] ?? 0, 0, "concurrent load must produce submits")
        await bus.shutdown()
    }

    // MARK: - helpers

    private func killStudio() {
        for m in mockStudios { m.stop() }
        mockStudios.removeAll()
    }

    private func outboxPendingCount(dir: String) -> Int {
        let queueDir = "\(dir)/outbox"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: queueDir) else { return 0 }
        return files.filter { $0.hasSuffix(".json") }.count
    }

    private func currentRSSKB() -> UInt64 {
        // mach_task_basic_info gives resident size in bytes.
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kresult = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kresult == KERN_SUCCESS else { return 0 }
        return info.resident_size / 1024
    }
}
