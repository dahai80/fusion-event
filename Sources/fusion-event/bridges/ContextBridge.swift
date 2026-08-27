import Foundation
import CryptoKit

public actor ContextBridge {
    private let sockPath: String
    private let timeoutSec: Int
    private let ttlSec: Int
    private var client: UDSClient?
    private var cache: [String: (context: ContextResult, expiryTs: UInt64)] = [:]
    private var cacheOrder: [String] = []
    private let cacheMaxEntries: Int

    public init(sockPath: String, timeoutSec: Int, ttlSec: Int, cacheMaxEntries: Int = 5000) {
        self.sockPath = sockPath
        self.timeoutSec = timeoutSec
        self.ttlSec = ttlSec
        self.cacheMaxEntries = cacheMaxEntries
        startPurgeLoop()
    }

    private nonisolated func startPurgeLoop() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.purgeExpired(now: UInt64(Date().timeIntervalSince1970 * 1000))
            }
        }
        FusionLog.bridge.info("context cache bounded LRU ttl purge=60s (A4: no unbounded growth)")
    }

    private func putCache(_ bucket: String, _ cr: ContextResult, now: UInt64) {
        if cache[bucket] == nil { cacheOrder.append(bucket) }
        cache[bucket] = (cr, now + UInt64(ttlSec) * 1000)
        if cache.count > cacheMaxEntries {
            let evict = cacheOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
    }

    private func purgeExpired(now: UInt64) {
        var expired: [String] = []
        for (k, v) in cache where v.expiryTs <= now {
            expired.append(k)
        }
        guard !expired.isEmpty else { return }
        for k in expired {
            cache.removeValue(forKey: k)
            cacheOrder.removeAll { $0 == k }
        }
        FusionLog.bridge.info("context cache purged \(expired.count) expired (A4), remaining \(self.cache.count)")
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
            putCache(bucket, cr, now: now)
            return cr
        } catch let err as UDSClientError {
            await resetClientOnError(err)
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

    private func resetClientOnError(_ err: UDSClientError) async {
        guard client != nil else { return }
        FusionLog.bridge.error("context reset client after \(err), discard poisoned connection")
        await client?.close()
        client = nil
    }
}
