import Foundation

public actor EventBus {
    private var subscribers: [UUID: AsyncStream<RawEvent>.Continuation] = [:]
    private let ruleEngine: RuleEngine
    private var ingestStream: AsyncStream<RawEvent>.Continuation?
    private var ingestStreamId: UUID?
    private var ingestDroppedCount: UInt64 = 0
    private var ingestInFlight: Int = 0
    private let ingestBuffer: Int = 8192
    private var backpressureActive: Bool = false
    private var backpressureObservers: [@Sendable () async -> Void] = []

    public init(ruleEngine: RuleEngine) {
        self.ruleEngine = ruleEngine
    }

    public func start() async {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: RawEvent.self, bufferingPolicy: .bufferingNewest(ingestBuffer))
        cont.onTermination = { [weak self] _ in
            Task { await self?.clearIngestStream() }
        }
        ingestStream = cont
        ingestStreamId = id
        let engine = ruleEngine
        Task { [weak self] in
            for await event in stream {
                await engine.process(event)
                await self?.ingestDrained()
            }
        }
        FusionLog.ipc.info("eventbus ingest loop start, buffer \(self.ingestBuffer) (A3: publish no longer serializes through process)")
    }

    public func observeBackpressure(_ handler: @escaping @Sendable () async -> Void) {
        backpressureObservers.append(handler)
    }

    private func ingestDrained() {
        if ingestInFlight > 0 { ingestInFlight -= 1 }
        if backpressureActive {
            backpressureActive = false
            FusionLog.ipc.info("eventbus ingest backpressure NORMAL (A10)")
            let observers = backpressureObservers
            Task { for h in observers { await h() } }
        }
    }

    public func drainIngest() async {
        while ingestInFlight > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func clearIngestStream() {
        if ingestStreamId != nil {
            ingestStream = nil
            ingestStreamId = nil
        }
    }

    public func publish(_ event: RawEvent) async {
        guard let cont = ingestStream else {
            FusionLog.ipc.error("eventbus ingest stream nil, drop event type=\(event.sourceType.rawValue, privacy: .public)")
            ingestDroppedCount += 1
            return
        }
        let yielded = cont.yield(event)
        switch yielded {
        case .terminated:
            ingestDroppedCount += 1
            FusionLog.ipc.error("eventbus ingest stream terminated, drop event type=\(event.sourceType.rawValue, privacy: .public)")
        case .dropped:
            ingestDroppedCount += 1
            if !backpressureActive {
                backpressureActive = true
                FusionLog.ipc.error("eventbus ingest buffer full (backpressure HIGH), drop oldest (A3/A10)")
                let observers = backpressureObservers
                Task { for h in observers { await h() } }
            }
        default:
            ingestInFlight += 1
        }
        for cont in subscribers.values {
            cont.yield(event)
        }
    }

    public func droppedEventCount() -> UInt64 { ingestDroppedCount }

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
        ingestStream?.finish()
        for cont in subscribers.values {
            cont.finish()
        }
        subscribers.removeAll()
    }
}
