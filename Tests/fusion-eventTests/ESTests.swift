import XCTest
@testable import fusion_event

final class ESTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-es-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeBus() async -> (EventBus, SourceRegistry, RuleEngine) {
        let store = RuleStore(dbPath: tmpDir + "es-rules.db", nodeId: "n1")
        let engine = RuleEngine(store: store, nodeId: "n1")
        await engine.loadFromStore()
        let bus = EventBus(ruleEngine: engine)
        let registry = SourceRegistry()
        return (bus, registry, engine)
    }

    func testESDegradesWithoutEntitlement() async {
        let (bus, registry, _) = await makeBus()
        let es = EndpointSecuritySource(bus: bus, registry: registry)
        await es.start()
        let on = await es.isEnabled()
        XCTAssertFalse(on, "ES must self-disable without entitlement/root (degrade to NSWorkspace)")
        await es.stop()
    }

    func testESStopIsIdempotent() async {
        let (bus, registry, _) = await makeBus()
        let es = EndpointSecuritySource(bus: bus, registry: registry)
        await es.start()
        await es.stop()
        await es.stop()
        let on = await es.isEnabled()
        XCTAssertFalse(on)
    }
}
