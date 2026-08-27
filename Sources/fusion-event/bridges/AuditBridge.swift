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
            "node_id": signal.nodeId
        ]
        let req = RPCRequest(method: "guard.audit", params: AnyCodable(params), id: .int(Int.random(in: 1...Int.max)))
        do {
            let resp = try await callWithTimeout(req)
            if let err = resp.error {
                FusionLog.bridge.error("guard.audit error code=\(err.code) \(err.message)")
                return decideDegrade(signal: signal, reason: "guard error \(err.code)")
            }
            guard let result = resp.result?.value as? [String: Any],
                  let decisionStr = result["decision"] as? String,
                  let decision = GuardDecision(rawValue: decisionStr) else {
                return decideDegrade(signal: signal, reason: "guard malformed response")
            }
            let res = GuardAuditResult(
                decision: decision,
                reason: result["reason"] as? String ?? "",
                riskLevel: result["risk_level"] as? Int ?? 0,
                auditId: result["audit_id"] as? String ?? ""
            )
            switch decision {
            case .pass: return .pass(res)
            case .block: return .block(res)
            case .challenge: return .challenge(res)
            }
        } catch let err as UDSClientError {
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
        let c = UDSClient(sockPath: sockPath)
        client = c
        return c
    }

    public func close() async {
        client = nil
    }
}
