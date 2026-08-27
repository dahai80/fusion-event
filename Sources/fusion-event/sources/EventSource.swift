import Foundation

public protocol EventSource: Sendable {
    var sourceType: SystemEventType { get }
    func start() async
    func stop() async
}

public actor SourceRegistry {
    private var sources: [EventSource] = []
    private var started: Set<String> = []
    private var counts: [String: UInt64] = [:]
    private var errors: [String: UInt64] = [:]

    public init() {}

    public func register(_ source: EventSource) {
        sources.append(source)
        counts[source.sourceType.rawValue] = 0
        errors[source.sourceType.rawValue] = 0
    }

    public func startAll() async {
        for s in sources {
            await s.start()
            started.insert(s.sourceType.rawValue)
            FusionLog.source.info("source start \(s.sourceType.rawValue, privacy: .public)")
        }
    }

    public func stopAll() async {
        for s in sources {
            await s.stop()
            started.remove(s.sourceType.rawValue)
            FusionLog.source.info("source stop \(s.sourceType.rawValue, privacy: .public)")
        }
    }

    public func tickCount(_ type: SystemEventType, isError: Bool = false) {
        if isError {
            errors[type.rawValue, default: 0] += 1
        } else {
            counts[type.rawValue, default: 0] += 1
        }
    }

    public func health() -> [String: [String: AnyCodable]] {
        var out: [String: [String: AnyCodable]] = [:]
        for s in sources {
            let t = s.sourceType.rawValue
            out[t] = [
                "enabled": AnyCodable(started.contains(t)),
                "events_total": AnyCodable(counts[t] ?? 0),
                "errors": AnyCodable(errors[t] ?? 0)
            ]
        }
        return out
    }
}
