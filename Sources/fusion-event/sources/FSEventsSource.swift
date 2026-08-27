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

    public init(watchPaths: [String], latencySec: Double, bus: EventBus, registry: SourceRegistry) {
        self.watchPaths = watchPaths
        self.latencySec = latencySec
        self.bus = bus
        self.registry = registry
    }

    public func start() async {
        let roots = self.watchPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else {
            FusionLog.source.notice("fsevents no valid watch paths (R1): file events disabled — configure fsevents_watch_paths to enable; whole-home-dir watch removed to avoid flood")
            return
        }
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let unmanaged = Unmanaged<FSEventsSource>.passRetained(self)
        let ptr = unmanaged.toOpaque()
        context.info = ptr
        infoPtr = ptr
        let flags: FSEventStreamCreateFlags = UInt32(kFSEventStreamCreateFlagFileEvents) | UInt32(kFSEventStreamCreateFlagNoDefer)
        let streamRef = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, eventPaths, eventFlags, eventIds in
                guard let info else { return }
                let me = Unmanaged<FSEventsSource>.fromOpaque(info).takeUnretainedValue()
                let pathCount = Int(numEvents)
                let paths: [String] = eventPaths.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: pathCount) { ptr in
                    (0..<pathCount).compactMap { i -> String? in
                        guard let cstr = ptr[i] else { return nil }
                        return String(cString: cstr)
                    }
                }
                let flags: [UInt32] = eventFlags.withMemoryRebound(to: UInt32.self, capacity: pathCount) { ptr in
                    (0..<pathCount).map { ptr[$0] }
                }
                Task { await me.handleEvents(paths: paths, flags: flags) }
            },
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latencySec,
            flags
        )
        guard let streamRef else {
            FusionLog.source.error("fsevents stream create fail")
            return
        }
        FSEventStreamSetDispatchQueue(streamRef, runLoop)
        if !FSEventStreamStart(streamRef) {
            FusionLog.source.error("fsevents stream start fail")
            return
        }
        stream = streamRef
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
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let count = UInt64(batchBuffer.count)
        await registry.tickCountN(.fileModified, n: count)
        for (path, flag) in batchBuffer {
            let event = RawEvent(
                sourceType: .fileModified,
                targetPath: path,
                timestamp: now,
                payload: ["flags": String(flag)],
                rawFlags: flag
            )
            await bus?.publish(event)
        }
        batchBuffer.removeAll()
    }

    public func stop() async {
        batchTask?.cancel()
        batchTask = nil
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

    private func handleEvents(paths: [String], flags: [UInt32]) async {
        for (i, path) in paths.enumerated() {
            let flag = flags[i]
            batchBuffer[path] = flag
        }
        if batchBuffer.count > 4096 {
            await flushBatch()
        }
    }
}
