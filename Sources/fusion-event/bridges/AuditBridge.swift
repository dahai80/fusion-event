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
        let params: [String: Any] = [
            "trigger_id": signal.triggerId,
            "event_type": signal.event.type.rawValue,
            "target_path": signal.event.targetPath ?? "",
            "target_agent": signal.rule.targetAgent,
            "payload": signal.event.payload,
            "node_id": signal.nodeId,
            "tenant_id": "default"
        ]
        let req = RPCRequest(method: "guard.audit", params: AnyCodable(params), id: .int(Int.random(in: 1...Int.max)))
        do {
            let resp = try await callWithTimeout(req)
            if let err = resp.error {
                if err.code == RPCErrorCode.guardBlock.rawValue {
                    FusionLog.bridge.notice("guard explicit block via RPC error code=\(err.code), event blocked (S0: no fail-open bypass)")
                    return .block(GuardAuditResult(decision: .block, reason: err.message, riskLevel: 0, auditId: ""))
                }
                FusionLog.bridge.error("guard.audit error code=\(err.code) \(err.message)")
                return decideDegrade(signal: signal, reason: "guard error \(err.code)")
            }
            guard let result = resp.result?.value as? [String: Any],
                let decisionStr = result["decision"] as? String
            else {
                return decideDegrade(signal: signal, reason: "guard malformed response")
            }
            let riskLevel = result["risk_level"] as? Int ?? 0
            let res = GuardAuditResult(
                decision: mapDecision(decisionStr),
                reason: result["reason"] as? String ?? "",
                riskLevel: riskLevel,
                auditId: result["audit_id"] as? String ?? ""
            )
            FusionLog.bridge.info("guard.audit decision=\(decisionStr, privacy: .public) risk=\(riskLevel) trigger=\(signal.triggerId, privacy: .public) audit_id=\(res.auditId, privacy: .public)")
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

    private nonisolated func mapDecision(_ s: String) -> GuardDecision {
        switch s {
        case "pass": return .pass
        case "challenge": return .challenge
        case "block": return .block
        default: return .block
        }
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
