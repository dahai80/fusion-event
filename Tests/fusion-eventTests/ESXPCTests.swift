import XCTest
import os
@testable import fusion_event

private final class XPCCaptureSink: TriggerSink, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [TriggerSignal]())
    var signals: [TriggerSignal] { lock.withLock { $0 } }
    func onTrigger(_ signal: TriggerSignal) async {
        lock.withLock { $0.append(signal) }
    }
}

final class ESXPCTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-xpc-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeChain() async -> (EventBus, RuleEngine, SourceRegistry, XPCCaptureSink) {
        let store = RuleStore(dbPath: tmpDir + "xpc-rules.db", nodeId: "n1")
        let engine = RuleEngine(store: store, nodeId: "n1")
        await engine.loadFromStore()
        let capture = XPCCaptureSink()
        await engine.setSink(capture)
        let bus = EventBus(ruleEngine: engine)
        await bus.start()
        let registry = SourceRegistry()
        return (bus, engine, registry, capture)
    }

    private func processRule() -> EventRule {
        EventRule(
            ruleName: "es-proc",
            eventType: .processTerminated,
            pathPattern: "/usr/bin/*",
            debounceMs: 0, throttleMs: 0,
            targetAgent: "fusion-code",
            targetGraphId: nil,
            enabled: true, maxRetries: 2, requireGuard: false
        )
    }

    func testXPCDeliversEventToEventBus() async {
        let (bus, engine, registry, capture) = await makeChain()
        _ = await engine.addRule(processRule())
        let server = ESXPCServer(bus: bus, registry: registry)
        guard let endpoint = await server.startAnonymous() else {
            XCTFail("es-xpc server failed to start")
            await server.stop()
            return
        }
        let enabled0 = await server.isEnabled()
        XCTAssertTrue(enabled0)
        let client = ESXPCMockClient(endpoint: endpoint)
        _ = await client.connect()
        let snap = ESSnapshotXPC(pid: 1234, execPath: "/usr/bin/ls", action: "exec", timestamp: 1000)
        let delivered = await client.deliver(snap)
        XCTAssertTrue(delivered, "mock client must deliver snapshot via xpc")
        await registry.waitForCount(.processTerminated, target: 1)
        await bus.drainIngest()
        await engine.flush()
        XCTAssertEqual(capture.signals.count, 1, "xpc-delivered ES event must reach EventBus and fire trigger")
        XCTAssertEqual(capture.signals.first?.event.type, .processTerminated)
        XCTAssertEqual(capture.signals.first?.event.targetPath, "/usr/bin/ls")
        XCTAssertEqual(capture.signals.first?.event.payload["pid"], "1234")
        XCTAssertEqual(capture.signals.first?.event.payload["source"], "endpoint-security")
        await client.close()
        await server.stop()
    }

    func testXPCMultipleEventsAllDelivered() async {
        let (bus, engine, registry, capture) = await makeChain()
        _ = await engine.addRule(processRule())
        let server = ESXPCServer(bus: bus, registry: registry)
        guard let endpoint = await server.startAnonymous() else {
            XCTFail("es-xpc server failed to start")
            await server.stop()
            return
        }
        let client = ESXPCMockClient(endpoint: endpoint)
        _ = await client.connect()
        for i in 0..<20 {
            let snap = ESSnapshotXPC(pid: Int32(1000 + i), execPath: "/usr/bin/echo", action: "exec", timestamp: UInt64(1000 + i))
            _ = await client.deliver(snap)
        }
        await registry.waitForCount(.processTerminated, target: 20)
        await bus.drainIngest()
        await engine.flush()
        XCTAssertGreaterThanOrEqual(capture.signals.count, 15, "most xpc events must reach EventBus (20 distinct paths/buckets)")
        await client.close()
        await server.stop()
    }

    func testXPCStopDisables() async {
        let (bus, _, registry, _) = await makeChain()
        let server = ESXPCServer(bus: bus, registry: registry)
        _ = await server.startAnonymous()
        let before = await server.isEnabled()
        XCTAssertTrue(before)
        await server.stop()
        let after = await server.isEnabled()
        XCTAssertFalse(after)
    }
}
