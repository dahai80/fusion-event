import Foundation
import CryptoKit

public enum Normalizer {
    public static func normalize(event: RawEvent, rule: EventRule, nodeId: String) -> TriggerSignal {
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
        let bucket = idempotencyBucket(timestamp: event.timestamp, debounceMs: rule.debounceMs)
        let idempotencyKey = computeIdempotencyKey(
            ruleName: rule.ruleName,
            eventType: event.sourceType,
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
        targetPath: String?,
        bucket: UInt64
    ) -> String {
        let path = targetPath ?? ""
        let raw = "\(ruleName)|\(eventType.rawValue)|\(path)|\(bucket)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
