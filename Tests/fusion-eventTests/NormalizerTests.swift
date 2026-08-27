import XCTest
@testable import fusion_event

final class NormalizerTests: XCTestCase {
    private func makeRule(debounceMs: Int = 0) -> EventRule {
        EventRule(
            ruleName: "r1", eventType: .fileModified, pathPattern: "/x/*",
            debounceMs: debounceMs, throttleMs: 0, targetAgent: "fusion-code",
            targetGraphId: nil, enabled: true, maxRetries: 2, requireGuard: false
        )
    }

    private func makeRaw(ts: UInt64, path: String = "/x/a.swift") -> RawEvent {
        RawEvent(sourceType: .fileModified, targetPath: path, timestamp: ts, payload: [:], rawFlags: 0)
    }

    func testNormalizeProducesStableIdempotencyWithinBucket() {
        let rule = makeRule(debounceMs: 200)
        let raw = makeRaw(ts: 1000)
        let s1 = Normalizer.normalize(event: raw, rule: rule, nodeId: "n1")
        let s2 = Normalizer.normalize(event: raw, rule: rule, nodeId: "n1")
        XCTAssertEqual(s1.idempotencyKey, s2.idempotencyKey)
        XCTAssertEqual(s1.event.type, .fileModified)
        XCTAssertEqual(s1.event.targetPath, "/x/a.swift")
        XCTAssertEqual(s1.nodeId, "n1")
    }

    func testIdempotencyKeyDiffersAcrossBuckets() {
        let rule = makeRule(debounceMs: 200)
        let s1 = Normalizer.normalize(event: makeRaw(ts: 100), rule: rule, nodeId: "n1")
        let s2 = Normalizer.normalize(event: makeRaw(ts: 500), rule: rule, nodeId: "n1")
        XCTAssertNotEqual(s1.idempotencyKey, s2.idempotencyKey)
    }

    func testIdempotencyKeySameWithinSameBucket() {
        let rule = makeRule(debounceMs: 200)
        let s1 = Normalizer.normalize(event: makeRaw(ts: 100), rule: rule, nodeId: "n1")
        let s2 = Normalizer.normalize(event: makeRaw(ts: 199), rule: rule, nodeId: "n1")
        XCTAssertEqual(s1.idempotencyKey, s2.idempotencyKey)
    }

    func testIdempotencyBucketDividesByDebounceMs() {
        XCTAssertEqual(Normalizer.idempotencyBucket(timestamp: 100, debounceMs: 200), 0)
        XCTAssertEqual(Normalizer.idempotencyBucket(timestamp: 199, debounceMs: 200), 0)
        XCTAssertEqual(Normalizer.idempotencyBucket(timestamp: 200, debounceMs: 200), 1)
    }

    func testIdempotencyBucketMinDivisorOne() {
        XCTAssertEqual(Normalizer.idempotencyBucket(timestamp: 500, debounceMs: 0), 500)
    }

    func testKeyDiffersForDifferentRuleOrPath() {
        let k1 = Normalizer.computeIdempotencyKey(ruleName: "r1", eventType: .fileModified, nodeId: "n1", targetPath: "/x/a.swift", bucket: 1)
        let k2 = Normalizer.computeIdempotencyKey(ruleName: "r2", eventType: .fileModified, nodeId: "n1", targetPath: "/x/a.swift", bucket: 1)
        let k3 = Normalizer.computeIdempotencyKey(ruleName: "r1", eventType: .fileModified, nodeId: "n1", targetPath: "/x/b.swift", bucket: 1)
        XCTAssertNotEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
    }

    func testKeyDiffersAcrossNodesSameFileBucket() {
        let kA = Normalizer.computeIdempotencyKey(ruleName: "r1", eventType: .fileModified, nodeId: "node-A", targetPath: "/x/a.swift", bucket: 1)
        let kB = Normalizer.computeIdempotencyKey(ruleName: "r1", eventType: .fileModified, nodeId: "node-B", targetPath: "/x/a.swift", bucket: 1)
        XCTAssertNotEqual(kA, kB, "F-IDEM-1: cross-node same file/bucket must not suppress each other")
    }

    func testKeyStableSameNodeFileBucket() {
        let a = Normalizer.computeIdempotencyKey(ruleName: "r1", eventType: .fileModified, nodeId: "node-A", targetPath: "/x/a.swift", bucket: 1)
        let b = Normalizer.computeIdempotencyKey(ruleName: "r1", eventType: .fileModified, nodeId: "node-A", targetPath: "/x/a.swift", bucket: 1)
        XCTAssertEqual(a, b, "same node/file/bucket key stable")
    }

    func testKeyDelimiterCollisionSafe() {
        let a = Normalizer.computeIdempotencyKey(ruleName: "r|1", eventType: .fileModified, nodeId: "n", targetPath: "x", bucket: 1)
        let b = Normalizer.computeIdempotencyKey(ruleName: "r", eventType: .fileModified, nodeId: "1|n", targetPath: "x", bucket: 1)
        XCTAssertNotEqual(a, b, "F-IDEM-1: delimiter collision must not collapse distinct fields")
    }

    func testTriggerIdUniquePerCall() {
        let rule = makeRule()
        let s1 = Normalizer.normalize(event: makeRaw(ts: 1), rule: rule, nodeId: "n1")
        let s2 = Normalizer.normalize(event: makeRaw(ts: 1), rule: rule, nodeId: "n1")
        XCTAssertNotEqual(s1.triggerId, s2.triggerId)
    }
}
