import Foundation

public actor EventBus {
    private var subscribers: [UUID: AsyncStream<RawEvent>.Continuation] = [:]
    private let ruleEngine: RuleEngine

    public init(ruleEngine: RuleEngine) {
        self.ruleEngine = ruleEngine
    }

    public func publish(_ event: RawEvent) async {
        await ruleEngine.process(event)
        for cont in subscribers.values {
            cont.yield(event)
        }
    }

    public func subscribe() -> (AsyncStream<RawEvent>, AsyncStream<RawEvent>.Continuation, UUID) {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: RawEvent.self, bufferingPolicy: .bufferingNewest(1024))
        cont.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = cont
        FusionLog.ipc.info("eventbus subscribe \(id.uuidString, privacy: .public), total \(self.subscribers.count, privacy: .public)")
        return (stream, cont, id)
    }

    public func removeSubscriber(_ id: UUID) {
        if subscribers.removeValue(forKey: id) != nil {
            FusionLog.ipc.info("eventbus unsubscribe \(id.uuidString, privacy: .public)")
        }
    }

    public func subscriberCount() -> Int { subscribers.count }

    public func shutdown() {
        for cont in subscribers.values {
            cont.finish()
        }
        subscribers.removeAll()
    }
}
