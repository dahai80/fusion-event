import XCTest
@testable import fusion_event

final class AnyCodableTests: XCTestCase {
    private func encode(_ value: Any) throws -> [String: Any] {
        let data = try JSONEncoder().encode(AnyCodable(value))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testScalarLeaves() throws {
        let out = try encode(["b": true, "i": 3, "s": "hi", "u": UInt64(5)])
        XCTAssertEqual(out["b"] as? Bool, true)
        XCTAssertEqual(out["i"] as? Int, 3)
        XCTAssertEqual(out["s"] as? String, "hi")
        XCTAssertEqual(out["u"] as? Int, 5)
    }

    func testNestedSourcesDictLeavesEncode() throws {
        let inner: [String: AnyCodable] = [
            "enabled": AnyCodable(true),
            "events_total": AnyCodable(7),
            "errors": AnyCodable(0)
        ]
        let src: [String: [String: AnyCodable]] = ["fileModified": inner]
        let out = try encode(["sources": src] as [String: Any])
        let sources = out["sources"] as? [String: Any]
        let fm = sources?["fileModified"] as? [String: Any]
        XCTAssertEqual(fm?["enabled"] as? Bool, true)
        XCTAssertEqual(fm?["events_total"] as? Int, 7)
        XCTAssertEqual(fm?["errors"] as? Int, 0)
    }

    func testDoubleWrappedLeafUnwraps() throws {
        let data = try JSONEncoder().encode(AnyCodable(["v": AnyCodable(true)]))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["v"] as? Bool, true)
    }

    func testRoundTripDecode() throws {
        let original: [String: Any] = ["a": 1, "b": "x", "c": ["d": true] as [String: Any]]
        let data = try JSONEncoder().encode(AnyCodable(original))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.value as? [String: Any]
        XCTAssertEqual(dict?["a"] as? Int, 1)
        XCTAssertEqual(dict?["b"] as? String, "x")
    }
}
