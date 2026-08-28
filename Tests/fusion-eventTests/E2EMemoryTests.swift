import XCTest
import os
@testable import fusion_event

// E2E integration against a REAL fusion-memory daemon (issue #4 CLOSED).
// NOT in default `swift test`. Two env gates:
//   FUSION_EVENT_E2E=1              — enable
//   FUSION_EVENT_E2E_MEMORY_SOCK    — real memory UDS socket (default ~/.fusion-memory/fusion-memory.sock)
// Seeds a test Interaction via `commit`, then calls fusion-event's own
// ContextBridge.retrieveContext to verify the real code path (query build +
// socket call + response parse + LRU) works against the fixed upstream.
// Cleans up: delete_scope by session_id (confirm=true). Only logs remain.

private func e2eEnabled() -> Bool {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E"] != nil
}

private func e2eMemorySock() -> String {
    ProcessInfo.processInfo.environment["FUSION_EVENT_E2E_MEMORY_SOCK"]
        ?? "\(NSHomeDirectory())/.fusion-memory/fusion-memory.sock"
}

final class E2EMemoryTests: XCTestCase {
    private func socketAlive(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK
    }

    private func makeSignal(targetPath: String, nodeId: String) -> TriggerSignal {
        let rule = EventRule(
            ruleName: "e2e-mem-rule",
            eventType: .fileModified,
            pathPattern: "/x/*",
            debounceMs: 0,
            throttleMs: 0,
            targetAgent: "fusion-code",
            targetGraphId: nil,
            enabled: true,
            maxRetries: 0,
            requireGuard: false
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

    // Real fusion-memory: commit interaction, retrieve via ContextBridge,
    // assert non-empty context + interaction_id present + cache_hit false.
    func testRetrieveContextRealMemory() async throws {
        try XCTSkipUnless(e2eEnabled(), "E2E: set FUSION_EVENT_E2E=1")
        let sock = e2eMemorySock()
        try XCTSkipUnless(socketAlive(sock), "E2E: real memory socket \(sock) absent — start fusion-memory daemon")

        let targetPath = "/Users/dahai/fusion/fusion-event/Sources/fusion-event/bridges/ContextBridge.swift"
        let sessionId = "fe-e2e-mem-\(getpid())"
        let interactionId = "fe-e2e-int-\(getpid())"
        let marker = "fe-e2e-mem-verified-marker"
        // ContextBridge builds query = "targetPath|event_type". Commit an
        // identical user_message so embedding match is guaranteed (top_k=5).
        let queryText = "\(targetPath)|fileModified"

        let commitParams: [String: Any] = [
            "session_id": sessionId,
            "interaction": [
                "id": interactionId,
                "session_id": sessionId,
                "turns": [
                    [
                        "turn_idx": 0,
                        "user_message": queryText,
                        "assistant_message": marker,
                        "tool_calls": []
                    ]
                ],
                "timestamp": UInt64(Date().timeIntervalSince1970),
                "metadata": [
                    "node_id": "e2e-n1",
                    "project_path": "/Users/dahai/fusion/fusion-event"
                ]
            ]
        ]
        let commitReq = RPCRequest(
            method: "commit",
            params: AnyCodable(commitParams),
            id: .int(1)
        )

        let seed = UDSClient(sockPath: sock, timeoutSec: 10)
        try await seed.connect()
        var commitOk = false
        do {
            let commitResp = try await seed.call(commitReq)
            if let err = commitResp.error {
                FusionLog.ipc.error("E2E memory commit error \(err.code) \(err.message)")
            } else if let res = commitResp.result?.value as? [String: Any] {
                let ids = (res["memory_ids"] as? [String]) ?? []
                let failed = (res["failed_turns"] as? [Any]) ?? []
                FusionLog.ipc.notice("E2E memory commit memory_ids=\(ids.count) failed_turns=\(failed.count)")
                commitOk = failed.isEmpty
            }
        } catch {
            FusionLog.ipc.error("E2E memory commit throw \(error.localizedDescription)")
        }
        await seed.close()
        XCTAssertTrue(commitOk, "commit must succeed with zero failed_turns before retrieve can be asserted")

        // Brief settle so the committed turn is indexed/embedded before retrieve.
        try? await Task.sleep(nanoseconds: 800_000_000)

        let ctx = ContextBridge(sockPath: sock, timeoutSec: 10, ttlSec: 60)
        let signal = makeSignal(targetPath: targetPath, nodeId: "e2e-n1")
        let result = await ctx.retrieveContext(signal: signal)
        FusionLog.ipc.notice(
            "E2E memory retrieve context.len=\(result.context.count) memoryIds=\(result.memoryIds) cacheHit=\(result.cacheHit) stale=\(result.contextStale)"
        )

        XCTAssertTrue(result.context.contains(marker), "retrieve context must contain the committed marker text")
        XCTAssertTrue(result.memoryIds.contains(interactionId), "retrieve memory_ids must contain the interaction_id \(interactionId)")
        XCTAssertFalse(result.cacheHit, "first retrieve must report cache_hit=false (memory-side never caches)")
        XCTAssertFalse(result.contextStale, "live retrieve must not be stale")

        await ctx.close()

        // Clean up process data: delete_scope by session_id, confirm=true (B5).
        let cleanup = UDSClient(sockPath: sock, timeoutSec: 10)
        try await cleanup.connect()
        let delReq = RPCRequest(
            method: "delete_scope",
            params: AnyCodable(["scope": sessionId, "confirm": true]),
            id: .int(2)
        )
        do {
            let delResp = try await cleanup.call(delReq)
            if let res = delResp.result?.value as? [String: Any] {
                let deleted = (res["deleted_count"] as? Int) ?? -1
                FusionLog.ipc.notice("E2E cleanup delete_scope session=\(sessionId, privacy: .public) deleted=\(deleted)")
            } else if let err = delResp.error {
                FusionLog.ipc.error("E2E cleanup delete_scope error \(err.code) \(err.message)")
            }
        } catch {
            FusionLog.ipc.error("E2E cleanup delete_scope throw \(error.localizedDescription)")
        }
        await cleanup.close()
    }
}
