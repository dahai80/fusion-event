import XCTest
@testable import fusion_event

final class RPCBatchTests: XCTestCase {

    func testDecodeSingleRequest() throws {
        let json = #"{"jsonrpc":"2.0","method":"ping","params":{},"id":1}"#
        let data = json.data(using: .utf8)!
        switch RPCCodec.decodeBatch(data) {
        case .single(let req):
            XCTAssertEqual(req.method, "ping")
            XCTAssertEqual(req.id, .int(1))
        default:
            XCTFail("expected single")
        }
    }

    func testDecodeBatchRequest() throws {
        let json = #"[{"jsonrpc":"2.0","method":"ping","id":1},{"jsonrpc":"2.0","method":"event.health","id":2}]"#
        let data = json.data(using: .utf8)!
        switch RPCCodec.decodeBatch(data) {
        case .batch(let reqs):
            XCTAssertEqual(reqs.count, 2)
            XCTAssertEqual(reqs[0].method, "ping")
            XCTAssertEqual(reqs[1].method, "event.health")
        default:
            XCTFail("expected batch (D5)")
        }
    }

    func testDecodeEmptyBatchMalformed() throws {
        let data = "[]".data(using: .utf8)!
        switch RPCCodec.decodeBatch(data) {
        case .malformed:
            break
        default:
            XCTFail("empty batch must be malformed (D5: JSON-RPC 2.0 spec)")
        }
    }

    func testDecodeGarbageMalformed() throws {
        let data = "not json".data(using: .utf8)!
        switch RPCCodec.decodeBatch(data) {
        case .malformed:
            break
        default:
            XCTFail("garbage must be malformed")
        }
    }

    func testNotificationHasNilId() throws {
        let json = #"{"jsonrpc":"2.0","method":"event.pong"}"#
        let data = json.data(using: .utf8)!
        switch RPCCodec.decodeBatch(data) {
        case .single(let req):
            XCTAssertNil(req.id, "notification (no id) should decode with nil id (D5)")
            XCTAssertEqual(req.method, "event.pong")
        default:
            XCTFail("expected single")
        }
    }

    func testProcessLaunchedTypeExists() throws {
        XCTAssertEqual(SystemEventType.processLaunched.rawValue, "processLaunched")
        XCTAssertEqual(SystemEventType.processTerminated.rawValue, "processTerminated")
        let ev = SystemEvent(
            eventId: "e1",
            type: .processLaunched,
            targetPath: "/usr/bin/true",
            timestamp: 1,
            payload: ["pid": "123"],
            nodeId: "n1"
        )
        let data = try JSONEncoder().encode(ev)
        let dec = try JSONDecoder().decode(SystemEvent.self, from: data)
        XCTAssertEqual(dec.type, .processLaunched)
    }

    func testDecodeRequestFailureReturnsNilNotCrash() throws {
        let data = "{bad".data(using: .utf8)!
        XCTAssertNil(RPCCodec.decodeRequest(data))
    }
}
