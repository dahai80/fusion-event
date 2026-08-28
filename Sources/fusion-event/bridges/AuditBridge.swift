import Foundation

public actor AuditBridge {
    private let sockPath: String
    private let timeoutSec: Int
    private var client: UDSClient?

    public init(sockPath: String, timeoutSec: Int) {
        self.sockPath = sockPath
        self.timeoutSec = timeoutSec
    }

    public enum AuditOutcome: Sendable {
        case pass(GuardAuditResult)
        case block(GuardAuditResult)
        case challenge(GuardAuditResult)
        case degradedFailOpen(String)
        case failClosed(String)
    }

    public func audit(signal: TriggerSignal) async -> AuditOutcome {
        let eventContent: [String: Any] = [
            "trigger_id": signal.triggerId,
            "event_type": signal.event.type.rawValue,
            "target_path": signal.event.targetPath ?? "",
            "target_agent": signal.rule.targetAgent,
            "payload": signal.event.payload,
            "node_id": signal.nodeId
        ]
        let contentJSON = (try? JSONSerialization.data(withJSONObject: eventContent, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let params: [String: Any] = [
            "content": contentJSON,
            "caller_epoch": 0,
            "tenant_id": "fusion-event",
            "requester": signal.nodeId,
            "action": "",
            "content_type": "json"
        ]
        let req = RPCRequest(method: "guard.evaluate", params: AnyCodable(params), id: .int(Int.random(in: 1...Int.max)))
        do {
            let resp = try await callWithTimeout(req)
            if let err = resp.error {
                if err.code == RPCErrorCode.guardBlock.rawValue {
                    FusionLog.bridge.notice("guard explicit block via RPC error code=\(err.code), event blocked (S0: no fail-open bypass)")
                    return .block(GuardAuditResult(decision: .block, reason: err.message, riskLevel: 0, auditId: ""))
                }
                FusionLog.bridge.error("guard.evaluate error code=\(err.code) \(err.message)")
                return decideDegrade(signal: signal, reason: "guard error \(err.code)")
            }
            guard let result = resp.result?.value as? [String: Any],
                  let actionStr = result["action"] as? String else {
                return decideDegrade(signal: signal, reason: "guard malformed response")
            }
            let riskLevel = parseRiskLevel(result["risk_level"])
            let res = GuardAuditResult(
                decision: mapAction(actionStr),
                reason: result["reason"] as? String ?? result["inferred_category"] as? String ?? "",
                riskLevel: riskLevel,
                auditId: result["action_id"] as? String ?? ""
            )
            FusionLog.bridge.info("guard.evaluate action=\(actionStr, privacy: .public) risk=L\(riskLevel) trigger=\(signal.triggerId, privacy: .public)")
            switch res.decision {
            case .pass: return .pass(res)
            case .block: return .block(res)
            case .challenge: return .challenge(res)
            }
        } catch let err as UDSClientError {
            await resetClientOnError(err)
            switch err {
            case .connectionFailed:
                return decideDegrade(signal: signal, reason: "guard not running")
            case .timeout:
                FusionLog.bridge.error("guard.audit timeout fail-open (H4)")
                return decideDegrade(signal: signal, reason: "guard audit timeout")
            case .ioError(let msg):
                FusionLog.bridge.error("guard.audit io error \(msg, privacy: .public)")
                return decideDegrade(signal: signal, reason: "guard io error")
            }
        } catch {
            return decideDegrade(signal: signal, reason: "guard unknown error \(error.localizedDescription)")
        }
    }

    private func decideDegrade(signal: TriggerSignal, reason: String) -> AuditOutcome {
        if signal.rule.requireGuard {
            FusionLog.bridge.error("guard degraded but require_guard=true -> fail-closed (H4): \(reason)")
            return .failClosed(reason)
        }
        FusionLog.bridge.notice("guard degraded fail-open: \(reason)")
        return .degradedFailOpen(reason)
    }

    private func callWithTimeout(_ req: RPCRequest) async throws -> RPCResponse {
        try await withTimeout(seconds: timeoutSec) { [weak self] in
            guard let self else { throw UDSClientError.connectionFailed }
            let c = await self.ensureClient()
            return try await c.call(req)
        }
    }

    private func ensureClient() -> UDSClient {
        if let c = client { return c }
        let c = UDSClient(sockPath: sockPath, timeoutSec: timeoutSec)
        client = c
        return c
    }

    private nonisolated func mapAction(_ s: String) -> GuardDecision {
        switch s {
        case "Allow": return .pass
        case "Preview": return .challenge
        case "Redact", "Block": return .block
        default: return .block
        }
    }

    private nonisolated func parseRiskLevel(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String, s.hasPrefix("L"), let n = Int(s.dropFirst()) { return n }
        return 0
    }

    private func resetClientOnError(_ err: UDSClientError) async {
        guard client != nil else { return }
        FusionLog.bridge.error("audit reset client after \(err), discard poisoned connection")
        await client?.close()
        client = nil
    }

    public func close() async {
        await client?.close()
        client = nil
    }
}
