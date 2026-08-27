import Foundation
import Network

public actor NetworkSource: EventSource {
    public let sourceType: SystemEventType = .networkStatusChanged
    private weak var bus: EventBus?
    private let registry: SourceRegistry
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "fusion-event.network")
    private var lastPath: String = ""

    public init(bus: EventBus, registry: SourceRegistry) {
        self.bus = bus
        self.registry = registry
    }

    public func start() async {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { await self?.handlePath(path) }
        }
        m.start(queue: queue)
        monitor = m
        FusionLog.source.info("network source start")
    }

    public func stop() async {
        monitor?.cancel()
        monitor = nil
        FusionLog.source.info("network source stop")
    }

    private func handlePath(_ path: NWPath) async {
        let sig = "\(String(describing: path.status))|\(path.availableInterfaces.map { $0.name }.joined(separator: ","))"
        guard sig != lastPath else { return }
        lastPath = sig
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        await registry.tickCount(.networkStatusChanged)
        await bus?.publish(RawEvent(
            sourceType: .networkStatusChanged,
            targetPath: nil,
            timestamp: now,
            payload: [
                "status": path.status == .satisfied ? "satisfied" : "unsatisfied",
                "interfaces": path.availableInterfaces.map { $0.name }.joined(separator: ",")
            ],
            rawFlags: 0
        ))
    }
}
