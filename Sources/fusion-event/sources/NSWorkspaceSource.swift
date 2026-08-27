import Foundation
import AppKit

public actor NSWorkspaceSource: EventSource {
    public let sourceType: SystemEventType = .processTerminated
    private weak var bus: EventBus?
    private let registry: SourceRegistry
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var mountObserver: NSObjectProtocol?

    public init(bus: EventBus, registry: SourceRegistry) {
        self.bus = bus
        self.registry = registry
    }

    public func start() async {
        let nc = NSWorkspace.shared.notificationCenter
        let launch = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let snap = NSWorkspaceSource.extract(note: note, isLaunch: true)
            Task { await self?.publishProcess(snap) }
        }
        let term = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let snap = NSWorkspaceSource.extract(note: note, isLaunch: false)
            Task { await self?.publishProcess(snap) }
        }
        observers = [launch, term]
        wakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let ev = RawEvent(
                sourceType: .networkStatusChanged, targetPath: nil, timestamp: now,
                payload: ["wake": "1"], rawFlags: 0
            )
            Task {
                await self?.registry.tickCount(.networkStatusChanged)
                await self?.bus?.publish(ev)
            }
        }
        FusionLog.source.info("nsworkspace source start")
    }

    struct ProcessSnap: Sendable {
        let pid: Int32
        let name: String
        let bundle: String
        let execPath: String?
        let isLaunch: Bool
        let timestamp: UInt64
    }

    nonisolated static func extract(note: Notification, isLaunch: Bool) -> ProcessSnap {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return ProcessSnap(
            pid: app?.processIdentifier ?? -1,
            name: app?.localizedName ?? "unknown",
            bundle: app?.bundleIdentifier ?? "",
            execPath: app?.executableURL?.path,
            isLaunch: isLaunch,
            timestamp: now
        )
    }

    private func publishProcess(_ snap: ProcessSnap) async {
        await registry.tickCount(.processTerminated)
        await bus?.publish(RawEvent(
            sourceType: .processTerminated,
            targetPath: snap.execPath,
            timestamp: snap.timestamp,
            payload: [
                "pid": String(snap.pid),
                "processName": snap.name,
                "bundleId": snap.bundle,
                "event": snap.isLaunch ? "launch" : "terminate"
            ],
            rawFlags: 0
        ))
    }

    public func stop() async {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        if let w = wakeObserver { nc.removeObserver(w) }
        if let m = mountObserver { nc.removeObserver(m) }
        observers.removeAll()
        wakeObserver = nil
        mountObserver = nil
        FusionLog.source.info("nsworkspace source stop")
    }

}
