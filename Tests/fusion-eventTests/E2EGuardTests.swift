import XCTest
import os
@testable import fusion_event

// E2E integration against a REAL fusion-guard daemon (issue #3 CLOSED).
// NOT in default `swift test`. Two env gates:
//   FUSION_EVENT_E2E=1              — enable
//   FUSION_EVENT_E2E_GUARD_SOCK    — real guard UDS socket (default /tmp/fusion-guard.sock)
// Calls fusion-event's own AuditBridge.audit against the fixed upstream
// guard.audit (D-10 contract), verifying the real code path (params build +
// socket call + AuditDecision response parse) returns the correct decision
// mapping for a benign path (pass) and a malicious path (block). No cleanup
// needed: guard only appends audit-chain rows (immutable ledger), no test
// data to delete.

private func e2eGuardEnabled() -> Bool {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E"] != nil
}

private func e2eGuardSock() -> String {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E_GUARD_SOCK"]
        ?? "/tmp/fusion-guard.sock"
}

final class E2EGuardTests: XCTestCase {
    private func socketAlive(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private func makeSignal(targetPath: String, nodeId: String) -> TriggerSignal {
        let rule = EventRule(
            ruleName: "e2e-guard-rule",
            eventType: .fileModified,
            pathPattern: "/x/*",
            debounceMs: 0,
            throttleMs: 0,
            targetAgent: "fusion-code",
            targetGraphId: nil,
            enabled: true,
            maxRetries: 0,
            requireGuard: true
        )
        let raw = RawEvent(
            sourceType: .fileModified,
            targetPath: targetPath,
            timestamp: UInt64(Date().timeIntervalSince1970),
            payload: [:],
            rawFlags: 0
        )
        return Normalizer.normalize(event: raw, rule: rule, nodeId: nodeId)
    }

    // Benign file path -> guard.audit content scan misses -> decision=pass.
    func testAuditPassRealGuard() async throws {
        try XCTSkipUnless(e2eGuardEnabled(), "E2E: set FUSION_EVENT_E2E=1")
        let sock = e2eGuardSock()
        try XCTSkipUnless(socketAlive(sock), "E2E: real guard socket \(sock) absent — start fusion-guard daemon")

        let audit = AuditBridge(sockPath: sock, timeoutSec: 5)
        let signal = makeSignal(
            targetPath: "/Users/dahai/fusion/fusion-event/Sources/fusion-event/bridges/AuditBridge.swift",
            nodeId: "e2e-guard-n1"
        )
        let outcome = await audit.audit(signal: signal)
        FusionLog.ipc.notice("E2E guard audit benign outcome=\(String(describing: outcome), privacy: .public)")
        guard case .pass(let res) = outcome else {
            return XCTFail("benign path must map to pass, got \(outcome)")
        }
        XCTAssertEqual(res.decision, .pass)
        XCTAssertNotEqual(res.auditId, "", "pass must carry a non-empty audit_id from the audit chain")
        await audit.close()
    }

    // Malicious path with shell injection (rm -rf) -> guard.audit regex hit -> decision=block.
    func testAuditBlockRealGuard() async throws {
        try XCTSkipUnless(e2eGuardEnabled(), "E2E: set FUSION_EVENT_E2E=1")
        let sock = e2eGuardSock()
        try XCTSkipUnless(socketAlive(sock), "E2E: real guard socket \(sock) absent — start fusion-guard daemon")

        let audit = AuditBridge(sockPath: sock, timeoutSec: 5)
        let signal = makeSignal(
            targetPath: "/tmp/x; rm -rf / --no-preserve-root",
            nodeId: "e2e-guard-n1"
        )
        let outcome = await audit.audit(signal: signal)
        FusionLog.ipc.notice("E2E guard audit malicious outcome=\(String(describing: outcome), privacy: .public)")
        guard case .block(let res) = outcome else {
            return XCTFail("rm-rf injection path must map to block, got \(outcome)")
        }
        XCTAssertEqual(res.decision, .block)
        XCTAssertNotEqual(res.auditId, "", "block must carry a non-empty audit_id from the audit chain")
        await audit.close()
    }
}
