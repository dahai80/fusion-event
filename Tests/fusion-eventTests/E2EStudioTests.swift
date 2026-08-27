import XCTest
import os
@testable import fusion_event

// E2E integration against a REAL agent-studio daemon.
// NOT in default `swift test`. Two env gates:
//   FUSION_EVENT_E2E=1              — enable
//   FUSION_EVENT_E2E_STUDIO_SOCK    — real studio UDS socket (default /tmp/fusion-studio.sock)
// Validates the only mature E2E chain: task.submit socket + params + response.
// Skips if real daemon socket absent. Input event field-name drift
// (camelCase vs snake_case, issue #250) does NOT block task creation —
// task_id returns, so this proves the socket/protocol/response contract.

private func e2eEnabled() -> Bool {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E"] != nil
}

private func e2eStudioSock() -> String {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E_STUDIO_SOCK"] ?? "/tmp/fusion-studio.sock"
}

private func e2eRawEvent(path: String, ts: UInt64) -> RawEvent {
    RawEvent(sourceType: .fileModified, targetPath: path, timestamp: ts, payload: [:], rawFlags: 0)
}

final class E2EStudioTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fes-e2e-\(getpid())/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func socketAlive(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    // Real agent-studio daemon: push N file events, verify task.submit
    // reaches real daemon and tasks created (submitted>0, failed==0).
    func testTaskSubmitRealStudio() async throws {
        try XCTSkipUnless(e2eEnabled(), "E2E: set FUSION_EVENT_E2E=1")
        let sock = e2eStudioSock()
        try XCTSkipUnless(socketAlive(sock), "E2E: real studio socket \(sock) absent — start agent-studio daemon")
        let gid = Int(getpid())
        let store = RuleStore(dbPath: tmpDir + "r.db", nodeId: "e2e-n1")
        let engine = RuleEngine(store: store, nodeId: "e2e-n1")
        await engine.loadFromStore()
        let eventLog = EventLog(logPath: tmpDir + "e.log")
        let outboxDir = tmpDir + "o"
        let dispatcher = Dispatcher(sockPath: sock, timeoutSec: 5, tokenBucketMax: 64, queueMax: 2048, eventLog: eventLog, outboxDir: outboxDir)
        let audit = AuditBridge(sockPath: tmpDir + "g.sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: tmpDir + "m.sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        let rule = EventRule(ruleName: "e2e-rule", eventType: .fileModified, pathPattern: "/src/**/*.swift", debounceMs: 0, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 0, requireGuard: false)
        let ok = await engine.addRule(rule)
        XCTAssertTrue(ok)
        await engine.setSink(dispatcher)
        let bus = EventBus(ruleEngine: engine)
        await bus.start()
        let n = 10
        let base = UInt64(gid)
        for i in 0..<n {
            await bus.publish(e2eRawEvent(path: "/src/e2e/\(i).swift", ts: base + UInt64(i)))
        }
        await bus.drainIngest()
        await engine.flush()
        let stats = await dispatcher.stats()
        FusionLog.ipc.notice("E2E task.submit real-studio submitted=\(stats["submitted"] ?? 0) failed=\(stats["failed"] ?? 0) retried=\(stats["retried"] ?? 0) sock=\(sock, privacy: .public)")
        XCTAssertGreaterThan(stats["submitted"] ?? 0, 0, "real studio must accept task.submit (socket+params+response contract)")
        XCTAssertEqual(stats["failed"] ?? 0, 0, "real studio submit must not fail on mature chain")
        await bus.shutdown()
        // Clean up process data: only logs remain (outbox drained on success).
        FusionLog.ipc.notice("E2E cleanup gid=\(gid, privacy: .public) outboxDir=\(outboxDir, privacy: .public)")
    }
}
