import Foundation
import CoreServices

public actor FSEventsSource: EventSource {
    public let sourceType: SystemEventType = .fileModified
    private let rootPath: String
    private weak var bus: EventBus?
    private var stream: FSEventStreamRef?
    private let registry: SourceRegistry
    private let runLoop = DispatchQueue(label: "fusion-event.fsevents")

    public init(rootPath: String, bus: EventBus, registry: SourceRegistry) {
        self.rootPath = rootPath
        self.bus = bus
        self.registry = registry
    }

    public func start() async {
        let root = self.rootPath
        guard FileManager.default.fileExists(atPath: root) else {
            FusionLog.source.error("fsevents root missing \(root, privacy: .public)")
            return
        }
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
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
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
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
        FusionLog.source.info("fsevents watch \(root, privacy: .public)")
    }

    public func stop() async {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handleEvents(paths: [String], flags: [UInt32]) async {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for (i, path) in paths.enumerated() {
            let flag = flags[i]
            await registry.tickCount(.fileModified)
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
}
