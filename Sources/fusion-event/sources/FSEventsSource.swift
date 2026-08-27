import Foundation
import CoreServices

public actor FSEventsSource: EventSource {
    public let sourceType: SystemEventType = .fileModified
    private let watchPaths: [String]
    private let latencySec: Double
    private weak var bus: EventBus?
    private var stream: FSEventStreamRef?
    private var infoPtr: UnsafeMutableRawPointer?
    private let registry: SourceRegistry
    private let runLoop = DispatchQueue(label: "fusion-event.fsevents")
    private var batchBuffer: [String: UInt32] = [:]
    private var batchTask: Task<Void, Never>?
    private let batchHardCap: Int = 8192

    public init(watchPaths: [String], latencySec: Double, bus: EventBus, registry: SourceRegistry) {
        self.watchPaths = watchPaths
        self.latencySec = latencySec
        self.bus = bus
        self.registry = registry
    }

    public func start() async {
        guard stream == nil else {
            FusionLog.source.notice("fsevents already started, skip duplicate (F-1: start idempotent)")
            return
        }
        let roots = self.watchPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else {
            FusionLog.source.notice("fsevents no valid watch paths (R1): file events disabled — configure fsevents_watch_paths to enable; whole-home-dir watch removed to avoid flood")
            return
        }
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let unmanaged = Unmanaged<FSEventsSource>.passRetained(self)
        let ptr = unmanaged.toOpaque()
        context.info = ptr
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents) | UInt32(kFSEventStreamCreateFlagNoDefer)
        let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, eventIds in
                guard let info else { return }
                let me = Unmanaged<FSEventsSource>.fromOpaque(info).takeUnretainedValue()
                let pathCount = Int(numEvents)
                var pairs: [(path: String, flag: UInt32)] = []
                eventPaths.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: pathCount) { pp in
                    eventFlags.withMemoryRebound(to: UInt32.self, capacity: pathCount) { fp in
                        for i in 0..<pathCount {
                            guard let cstr = pp[i] else { continue }
                            pairs.append((String(cString: cstr), fp[i]))
                        }
                    }
                }
                Task { await me.handleEvents(pairs: pairs) }
            },
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latencySec,
            flags
        )
        guard let streamRef else {
            FusionLog.source.error("fsevents stream create fail")
            Unmanaged<FSEventsSource>.fromOpaque(ptr).release()
            return
        }
        FSEventStreamSetDispatchQueue(streamRef, runLoop)
        if !FSEventStreamStart(streamRef) {
            FusionLog.source.error("fsevents stream start fail")
            FSEventStreamRelease(streamRef)
            Unmanaged<FSEventsSource>.fromOpaque(ptr).release()
            return
        }
        stream = streamRef
        infoPtr = ptr
        startBatchFlush()
        FusionLog.source.info("fsevents watch \(roots.count) paths latency=\(self.latencySec)s (R1: whitelist, no whole-home-dir)")
    }

    private func startBatchFlush() {
        let intervalNs = UInt64(max(Int(latencySec * 1000), 50)) * 1_000_000
        batchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { break }
                await self?.flushBatch()
            }
        }
    }

    private func flushBatch() async {
        guard !batchBuffer.isEmpty else { return }
        let snapshot = batchBuffer
        batchBuffer.removeAll()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let count = UInt64(snapshot.count)
        await registry.tickCountN(.fileModified, n: count)
        for (path, flag) in snapshot {
            let event = RawEvent(
                sourceType: .fileModified,
                targetPath: path,
                timestamp: now,
                payload: ["flags": String(flag)],
                rawFlags: flag
            )
            await bus?.publish(event)
        }
    }

    public func stop() async {
        batchTask?.cancel()
        batchTask = nil
        await flushBatch()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let ptr = infoPtr {
            Unmanaged<FSEventsSource>.fromOpaque(ptr).release()
            infoPtr = nil
        }
        FusionLog.source.info("fsevents stop")
    }

    private func handleEvents(pairs: [(path: String, flag: UInt32)]) async {
        for pair in pairs {
            batchBuffer[pair.path] = pair.flag
        }
        if batchBuffer.count > batchHardCap {
            FusionLog.source.notice("fsevents batch hard cap \(self.batchHardCap), flush now (P4-4: bounded)")
            await flushBatch()
        }
    }
}
