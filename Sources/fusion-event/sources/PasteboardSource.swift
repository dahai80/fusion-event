import Foundation
import AppKit

public actor PasteboardSource: EventSource {
    public let sourceType: SystemEventType = .clipboardChanged
    private weak var bus: EventBus?
    private let registry: SourceRegistry
    private var lastCount: Int = 0
    private var timer: Task<Void, Never>?
    private let intervalSec: UInt64 = 2

    public init(bus: EventBus, registry: SourceRegistry) {
        self.bus = bus
        self.registry = registry
    }

    public func start() async {
        lastCount = NSPasteboard.general.changeCount
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let ns = (self?.intervalSec ?? 2) * 1_000_000_000
                try? await Task.sleep(nanoseconds: ns)
                await self?.poll()
            }
        }
        FusionLog.source.info("pasteboard source start (E3: SLA >1-2s, excluded from <100ms)")
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
        FusionLog.source.info("pasteboard source stop")
    }

    private func poll() async {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }
        lastCount = count
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        await registry.tickCount(.clipboardChanged)
        await bus?.publish(RawEvent(
            sourceType: .clipboardChanged,
            targetPath: nil,
            timestamp: now,
            payload: ["change": "1"],
            rawFlags: 0
        ))
    }
}
