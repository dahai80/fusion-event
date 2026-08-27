import Foundation
import CryptoKit

public enum Normalizer {
    public static func normalize(event: RawEvent, rule: EventRule, nodeId: String, dedupTs: UInt64? = nil) -> TriggerSignal {
        let triggerId = UUID().uuidString
        let eventId = UUID().uuidString
        let systemEvent = SystemEvent(
            eventId: eventId,
            type: event.sourceType,
            targetPath: event.targetPath,
            timestamp: event.timestamp,
            payload: event.payload,
            nodeId: nodeId
        )
        let tsForBucket = dedupTs ?? event.timestamp
        let bucket = idempotencyBucket(timestamp: tsForBucket, debounceMs: rule.debounceMs)
        let idempotencyKey = computeIdempotencyKey(
            ruleName: rule.ruleName,
            eventType: event.sourceType,
            nodeId: nodeId,
            targetPath: event.targetPath,
            bucket: bucket
        )
        return TriggerSignal(
            event: systemEvent,
            rule: rule,
            triggerId: triggerId,
            idempotencyKey: idempotencyKey,
            nodeId: nodeId
        )
    }

    public static func idempotencyBucket(timestamp: UInt64, debounceMs: Int) -> UInt64 {
        let divisor = UInt64(max(debounceMs, 1))
        return timestamp / divisor
    }

    public static func computeIdempotencyKey(
        ruleName: String,
        eventType: SystemEventType,
        nodeId: String,
        targetPath: String?,
        bucket: UInt64
    ) -> String {
        let path = targetPath ?? ""
        let escRule = ruleName.replacingOccurrences(of: "|", with: "\\|")
        let escNode = nodeId.replacingOccurrences(of: "|", with: "\\|")
        let escPath = path.replacingOccurrences(of: "|", with: "\\|")
        let escBucket = String(bucket).replacingOccurrences(of: "|", with: "\\|")
        let raw = "\(escRule)|\(eventType.rawValue)|\(escNode)|\(escPath)|\(escBucket)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
