import XCTest
import os
@testable import fusion_event

// E2E subscribe/push contract (fusion-studio issue #346 — studio consumes the
// fusion-event stream over UDS). NOT in default `swift test`. Env gate:
//   FUSION_EVENT_E2E=1  — enable
// Starts a real IPCServer on a temp socket, connects a raw NDJSON UDS client
// (the studio EventBridge consumer path), and verifies the frozen push contract:
//   - event.subscribe -> {subscribed:true}
//   - event.notification push: params.event{eventId,type,targetPath,timestamp,
//     payload,nodeId} + params.source
//   - event.heartbeat push (15s) + event.pong keeps the connection alive
// No real source daemons needed: events are published directly via EventBus.

private func e2ePushEnabled() -> Bool {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E"] != nil
}

final class E2ESubscribePushTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fes-push-\(getpid())/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    // Raw NDJSON UDS client: connect with a short recv timeout so reads do not block forever.
    private func connectUDS(_ path: String) -> Int32 {
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return -1 }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathC = path.utf8CString
        let pathLen = min(pathC.count, MemoryLayout.size(ofValue: addr.sun_path))
        _ = pathC.withUnsafeBufferPointer { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(src.baseAddress!),
                    count: pathLen
                ))
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { Darwin.close(sock); return -1 }
        return sock
    }

    private func sendLine(_ sock: Int32, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var buf = data
        buf.append(0x0A)
        _ = buf.withUnsafeBytes { Darwin.write(sock, $0.baseAddress, buf.count) }
    }

    // Read up to `maxLines` NDJSON lines within `timeoutSec`. Returns parsed JSON objects.
    // Recv timeout is 1s per call; loop until we have enough lines or the deadline passes.
    private func readLines(_ sock: Int32, maxLines: Int, timeoutSec: Double) async -> [[String: Any]] {
        var out: [[String: Any]] = []
        var lineBuf = Data()
        var readBuf = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeoutSec)
        while out.count < maxLines && Date() < deadline {
            let n = readBuf.withUnsafeMutableBufferPointer { Darwin.read(sock, $0.baseAddress!, $0.count) }
            if n <= 0 {
                try? await Task.sleep(nanoseconds: 3_000_000)
                continue
            }
            lineBuf.append(contentsOf: readBuf[0..<n])
            while let nl = lineBuf.firstIndex(of: 0x0A) {
                let line = lineBuf.subdata(in: 0..<nl)
                lineBuf.removeSubrange(0...nl)
                guard !line.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                out.append(json)
                if out.count >= maxLines { return out }
            }
        }
        return out
    }

    // Build a minimal IPCServer on a temp socket with EventBus wired for direct publish.
    private func buildServer(nodeId: String) async -> (IPCServer, EventBus, RPCMethods) {
        let store = RuleStore(dbPath: tmpDir + "r.db", nodeId: nodeId)
        let ruleEngine = RuleEngine(store: store, nodeId: nodeId)
        let eventLog = EventLog(logPath: tmpDir + "e.log")
        await ruleEngine.setEventLog(eventLog)
        await ruleEngine.loadFromStore()
        let metrics = MetricsCollector()
        let dispatcher = Dispatcher(
            sockPath: tmpDir + "studio.sock", timeoutSec: 2,
            tokenBucketMax: 64, queueMax: 2048,
            eventLog: eventLog, outboxDir: tmpDir
        )
        let audit = AuditBridge(sockPath: tmpDir + "g.sock", timeoutSec: 1)
        let ctx = ContextBridge(sockPath: tmpDir + "m.sock", timeoutSec: 1, ttlSec: 60)
        await dispatcher.setBridges(audit: audit, context: ctx)
        await dispatcher.setMetrics(metrics)
        await ruleEngine.setSink(dispatcher)
        let bus = EventBus(ruleEngine: ruleEngine)
        await bus.setMetrics(metrics)
        await bus.start()
        let registry = SourceRegistry()
        let config = FusionEventConfig.load(dataDir: tmpDir)
        let methods = RPCMethods(
            ruleEngine: ruleEngine, eventLog: eventLog,
            dispatcher: dispatcher, registry: registry, config: config,
            metrics: metrics
        )
        let sockPath = tmpDir + "ipc.sock"
        let ipc = IPCServer(
            sockPath: sockPath, methods: methods, bus: bus,
            heartbeatSec: 15, deadSec: 45, nodeId: nodeId
        )
        await ipc.start()
        return (ipc, bus, methods)
    }

    // Subscribe + event.notification push: client subscribes, server pushes
    // one notification per published RawEvent with the frozen #346 field shape.
    func testSubscribeAndNotificationPush() async throws {
        try XCTSkipUnless(e2ePushEnabled(), "E2E: set FUSION_EVENT_E2E=1")
        let nodeId = "e2e-push-n1"
        let (ipc, bus, _) = await buildServer(nodeId: nodeId)
        let sockPath = tmpDir + "ipc.sock"

        // Server start is async (accept loop in a Task); give it a moment to bind.
        try? await Task.sleep(nanoseconds: 200_000_000)
        var st = stat()
        try XCTSkipUnless(stat(sockPath, &st) == 0, "E2E: server socket \(sockPath) not bound")

        let sock = connectUDS(sockPath)
        XCTAssertGreaterThanOrEqual(sock, 0, "E2E: client connect failed")
        guard sock >= 0 else { await ipc.stop(); await bus.shutdown(); return }

        sendLine(sock, ["jsonrpc": "2.0", "id": 1, "method": "event.subscribe"])

        // Subscriber is registered on connection accept (handleClient -> bus.subscribe),
        // not on the subscribe line. Wait briefly for the accept Task to register it,
        // then publish 3 events so the push path fires before we read.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let base = UInt64(getpid())
        for i in 0..<3 {
            await bus.publish(RawEvent(
                sourceType: .fileModified, targetPath: "/e2e/push/\(i).swift",
                timestamp: base + UInt64(i), payload: ["i": "\(i)"], rawFlags: 0
            ))
        }

        // ACK first, then notifications for the 3 published events.
        let lines = await readLines(sock, maxLines: 4, timeoutSec: 3)
        Darwin.close(sock)

        let ack = lines.first { $0["id"] != nil }
        XCTAssertNotNil(ack, "E2E: event.subscribe ACK missing")
        let subscribed = (ack?["result"] as? [String: Any])?["subscribed"] as? Bool
        XCTAssertEqual(subscribed, true, "E2E: subscribe ACK must be {subscribed:true}")

        let notes = lines.filter { $0["method"] as? String == "event.notification" }
        XCTAssertGreaterThanOrEqual(notes.count, 3, "E2E: expected 3 event.notification pushes, got \(notes.count)")

        for note in notes.prefix(3) {
            let params = note["params"] as? [String: Any]
            XCTAssertNotNil(params, "E2E: event.notification missing params")
            XCTAssertEqual(params?["source"] as? String, "fileModified", "E2E: params.source must be raw source type string")
            let ev = params?["event"] as? [String: Any]
            XCTAssertNotNil(ev?["eventId"] as? String, "E2E: event.eventId missing")
            XCTAssertEqual(ev?["type"] as? String, "fileModified")
            XCTAssertNotNil(ev?["targetPath"] as? String, "E2E: event.targetPath missing")
            XCTAssertNotNil(ev?["timestamp"], "E2E: event.timestamp missing")
            XCTAssertNotNil(ev?["payload"], "E2E: event.payload missing")
            XCTAssertEqual(ev?["nodeId"] as? String, nodeId, "E2E: event.nodeId must equal server nodeId")
        }
        FusionLog.ipc.notice("E2E subscribe/push ok ack=\(ack != nil) notes=\(notes.count, privacy: .public)")

        await ipc.stop()
        await bus.shutdown()
    }

    // Heartbeat + pong: server pushes event.heartbeat every 15s; client replies
    // event.pong and must NOT be kicked (deadSec=45). Verifies the keepalive
    // half of the #346 long-connection lifecycle.
    func testHeartbeatPongKeepsConnection() async throws {
        try XCTSkipUnless(e2ePushEnabled(), "E2E: set FUSION_EVENT_E2E=1")
        let nodeId = "e2e-push-n2"
        let (ipc, bus, _) = await buildServer(nodeId: nodeId)
        let sockPath = tmpDir + "ipc.sock"

        try? await Task.sleep(nanoseconds: 200_000_000)
        var st = stat()
        try XCTSkipUnless(stat(sockPath, &st) == 0, "E2E: server socket \(sockPath) not bound")

        let sock = connectUDS(sockPath)
        XCTAssertGreaterThanOrEqual(sock, 0, "E2E: client connect failed")
        guard sock >= 0 else { await ipc.stop(); await bus.shutdown(); return }

        sendLine(sock, ["jsonrpc": "2.0", "id": 1, "method": "event.subscribe"])
        // Drain the subscribe ACK before waiting for the heartbeat.
        _ = await readLines(sock, maxLines: 1, timeoutSec: 2)

        // Wait for the first heartbeat (15s interval). Read up to 18s.
        let hb = await readLines(sock, maxLines: 1, timeoutSec: 18)
        let heartbeat = hb.first { $0["method"] as? String == "event.heartbeat" }
        XCTAssertNotNil(heartbeat, "E2E: event.heartbeat not pushed within 18s")
        FusionLog.ipc.notice("E2E heartbeat received=\(heartbeat != nil)")

        // Reply pong and confirm the connection survives (server does not close
        // on a fresh pong). A subsequent event.publish should still push to us.
        sendLine(sock, ["jsonrpc": "2.0", "method": "event.pong"])
        let raw = RawEvent(
            sourceType: .fileModified, targetPath: "/e2e/pong-survive.swift",
            timestamp: UInt64(Date().timeIntervalSince1970), payload: [:], rawFlags: 0
        )
        await bus.publish(raw)
        let after = await readLines(sock, maxLines: 1, timeoutSec: 3)
        let survived = after.contains { $0["method"] as? String == "event.notification" }
        XCTAssertTrue(survived, "E2E: connection killed after pong — client still received push, keepalive contract holds")
        FusionLog.ipc.notice("E2E pong-keepalive survived=\(survived)")

        Darwin.close(sock)
        await ipc.stop()
        await bus.shutdown()
    }
}
