import Foundation
import CryptoKit

public actor ContextBridge {
    private let sockPath: String
    private let timeoutSec: Int
    private let ttlSec: Int
    private var client: UDSClient?
    private var cache: [String: (context: ContextResult, expiryTs: UInt64)] = [:]

    public init(sockPath: String, timeoutSec: Int, ttlSec: Int) {
        self.sockPath = sockPath
        self.timeoutSec = timeoutSec
        self.ttlSec = ttlSec
    }

    public func retrieveContext(signal: TriggerSignal) async -> ContextResult {
        let query = "\(signal.event.targetPath ?? "")|\(signal.event.type.rawValue)"
        let bucket = sha256(query)
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if let cached = cache[bucket], cached.expiryTs > now {
            FusionLog.bridge.debug("context cache hit \(bucket, privacy: .public)")
            return cached.context
        }
        let params: [String: Any] = [
            "trigger_id": signal.triggerId,
            "query": query,
            "top_k": 5,
            "node_id": signal.nodeId
        ]
        let req = RPCRequest(method: "memory.retrieve_context", params: AnyCodable(params), id: .int(Int.random(in: 1...Int.max)))
        do {
            let resp = try await callWithTimeout(req)
            if let err = resp.error {
                FusionLog.bridge.error("memory error \(err.code) \(err.message)")
                return fallback(bucket: bucket, reason: "memory error")
            }
            guard let result = resp.result?.value as? [String: Any] else {
                return fallback(bucket: bucket, reason: "memory malformed")
            }
            let ctx = result["context"] as? String ?? ""
            let ids = (result["memory_ids"] as? [String]) ?? []
            let hit = result["cache_hit"] as? Bool ?? false
            let cr = ContextResult(context: ctx, memoryIds: ids, cacheHit: hit, contextStale: false)
            cache[bucket] = (cr, now + UInt64(ttlSec) * 1000)
            return cr
        } catch let err as UDSClientError {
            switch err {
            case .connectionFailed:
                FusionLog.bridge.notice("memory not running -> fallback")
                return fallback(bucket: bucket, reason: "memory not running")
            case .timeout:
                FusionLog.bridge.error("memory retrieve timeout -> fallback stale (H4)")
                return fallback(bucket: bucket, reason: "memory timeout")
            case .ioError(let msg):
                FusionLog.bridge.error("memory io error \(msg, privacy: .public) -> fallback")
                return fallback(bucket: bucket, reason: "memory io error")
            }
        } catch {
            return fallback(bucket: bucket, reason: "memory unknown \(error.localizedDescription)")
        }
    }

    private func fallback(bucket: String, reason: String) -> ContextResult {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        if let cached = cache[bucket] {
            FusionLog.bridge.notice("context fallback to stale cache \(bucket, privacy: .public)")
            return ContextResult(
                context: cached.context.context,
                memoryIds: cached.context.memoryIds,
                cacheHit: false,
                contextStale: true
            )
        }
        FusionLog.bridge.notice("context fallback empty \(reason, privacy: .public)")
        return ContextResult(context: "", memoryIds: [], cacheHit: false, contextStale: false)
    }

    private func sha256(_ s: String) -> String {
        let hash = SHA256.hash(data: Data(s.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
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
}
