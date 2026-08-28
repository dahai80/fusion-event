import XCTest
import os.lock
@testable import fusion_event

// Verifies AuditBridge contract against fusion-guard guard.evaluate
// (issue #3, direction B: fusion-event adapts to upstream frozen contract).
// Mock guard server returns GuardVerdict shape; asserts action mapping:
// Allow→pass, Block→block, Redact→block, Preview→challenge.
// NOT degrade-path: real socket + real response parse.

private final class MockGuard: @unchecked Sendable {
    private let sockPath: String
    private var listenFd: Int32 = -1
    private var serverTask: Task<Void, Never>?
    private var verdictJSON: String
    private let connLock = OSAllocatedUnfairLock(initialState: [Int32]())

    init(sockPath: String, verdictJSON: String) {
        self.sockPath = sockPath
        self.verdictJSON = verdictJSON
    }

    func start() throws {
        unlink(sockPath)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let count = min(pathBytes.count - 1, dst.count - 1)
            for i in 0..<count { dst[i] = UInt8(bitPattern: pathBytes[i]) }
        }
        var bound = false
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bound = Darwin.bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else { Darwin.close(listenFd); listenFd = -1; throw POSIXError(.EIO) }
        Darwin.listen(listenFd, 16)
        let lfd = listenFd
        let v = verdictJSON
        serverTask = Task { [weak self] in
            while !Task.isCancelled {
                let cfd = Darwin.accept(lfd, nil, nil)
                if cfd < 0 { break }
                self?.connLock.withLock { $0.append(cfd) }
                Task { self?.handleConn(fd: cfd, verdict: v) }
            }
        }
    }

    private nonisolated func handleConn(fd: Int32, verdict: String) {
        var nosig: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var byte: [UInt8] = [0]
        while true {
            var buf = Data()
            var gotLine = false
            while !gotLine {
                let n = Darwin.recv(fd, &byte, 1, 0)
                if n <= 0 {
                    Darwin.close(fd)
                    self.connLock.withLock { $0.removeAll { $0 == fd } }
                    return
                }
                if byte[0] == 0x0A { gotLine = true } else { buf.append(byte[0]) }
            }
            let idStr = extractId(buf)
            let resp = #"{"jsonrpc":"2.0","id":\#(idStr),"result":\#(verdict)}"#
            let respData = (resp + "\n").data(using: .utf8) ?? Data()
            _ = respData.withUnsafeBytes { b -> Int in
                guard let base = b.baseAddress else { return -1 }
                return Darwin.send(fd, base, respData.count, 0)
            }
        }
    }

    private nonisolated func extractId(_ data: Data) -> String {
        guard let s = String(data: data, encoding: .utf8),
              let r = s.range(of: "\"id\":") else { return "1" }
        let rest = s[r.upperBound...]
        let num = rest.prefix { $0.isNumber }
        if !num.isEmpty { return String(num) }
        return "1"
    }

    func stop() {
        serverTask?.cancel()
        if listenFd >= 0 { Darwin.close(listenFd); listenFd = -1 }
        let conns = connLock.withLock { fds -> [Int32] in
            let copy = fds
            fds.removeAll()
            return copy
        }
        for fd in conns { Darwin.close(fd) }
        unlink(sockPath)
    }
}

final class AuditBridgeTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-audit-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeSignal(requireGuard: Bool = false) -> TriggerSignal {
        let rule = EventRule(ruleName: "r1", eventType: .fileModified, pathPattern: "/x/*", debounceMs: 0, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 0, requireGuard: requireGuard)
        let raw = RawEvent(sourceType: .fileModified, targetPath: "/x/a.swift", timestamp: 1000, payload: [:], rawFlags: 0)
        return Normalizer.normalize(event: raw, rule: rule, nodeId: "n1")
    }

    private func startMockGuard(verdict: String) throws -> (String, MockGuard) {
        let path = tmpDir + "guard.sock"
        let m = MockGuard(sockPath: path, verdictJSON: verdict)
        try m.start()
        return (path, m)
    }

    func testEvaluateAllowMapsToPass() async throws {
        let v = #"{"action":"Allow","risk_level":"L1","reason":"ok","stage":"Stage1","requires_approval":false,"redacted_content":null,"seatbelt_required":false,"action_id":"aid-1","verdict_epoch":1,"verdict_ttl_secs":30,"inferred_category":"file"}"#
        let (path, mock) = try startMockGuard(verdict: v)
        defer { mock.stop() }
        let audit = AuditBridge(sockPath: path, timeoutSec: 2)
        let outcome = await audit.audit(signal: makeSignal())
        guard case .pass(let res) = outcome else { return XCTFail("Allow must map to pass, got \(outcome)") }
        XCTAssertEqual(res.decision, .pass)
        XCTAssertEqual(res.riskLevel, 1)
        XCTAssertEqual(res.auditId, "aid-1")
        await audit.close()
    }

    func testEvaluateBlockMapsToBlock() async throws {
        let v = #"{"action":"Block","risk_level":"L4","reason":"malicious","stage":"Stage2","requires_approval":true,"redacted_content":null,"seatbelt_required":true,"action_id":"aid-2","verdict_epoch":1,"verdict_ttl_secs":30,"inferred_category":"shell"}"#
        let (path, mock) = try startMockGuard(verdict: v)
        defer { mock.stop() }
        let audit = AuditBridge(sockPath: path, timeoutSec: 2)
        let outcome = await audit.audit(signal: makeSignal())
        guard case .block(let res) = outcome else { return XCTFail("Block must map to block, got \(outcome)") }
        XCTAssertEqual(res.decision, .block)
        XCTAssertEqual(res.riskLevel, 4)
        await audit.close()
    }

    func testEvaluateRedactMapsToBlock() async throws {
        let v = #"{"action":"Redact","risk_level":"L3","reason":"secret","stage":"Stage1","requires_approval":false,"redacted_content":"<redacted>","seatbelt_required":false,"action_id":"aid-3","verdict_epoch":1,"verdict_ttl_secs":30,"inferred_category":"text"}"#
        let (path, mock) = try startMockGuard(verdict: v)
        defer { mock.stop() }
        let audit = AuditBridge(sockPath: path, timeoutSec: 2)
        let outcome = await audit.audit(signal: makeSignal())
        guard case .block = outcome else { return XCTFail("Redact must map to block (content high-risk), got \(outcome)") }
        await audit.close()
    }

    func testEvaluatePreviewMapsToChallenge() async throws {
        let v = #"{"action":"Preview","risk_level":"L2","reason":"suspicious","stage":"Stage1","requires_approval":true,"redacted_content":null,"seatbelt_required":false,"action_id":"aid-4","verdict_epoch":1,"verdict_ttl_secs":30,"inferred_category":"code"}"#
        let (path, mock) = try startMockGuard(verdict: v)
        defer { mock.stop() }
        let audit = AuditBridge(sockPath: path, timeoutSec: 2)
        let outcome = await audit.audit(signal: makeSignal())
        guard case .challenge(let res) = outcome else { return XCTFail("Preview must map to challenge, got \(outcome)") }
        XCTAssertEqual(res.decision, .challenge)
        await audit.close()
    }
}
