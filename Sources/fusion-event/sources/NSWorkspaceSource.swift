import Foundation
import AppKit

public actor NSWorkspaceSource: EventSource {
    public let sourceType: SystemEventType = .processTerminated
    private weak var bus: EventBus?
    private let registry: SourceRegistry
    private var observers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
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
                sourceType: .systemWake, targetPath: nil, timestamp: now,
                payload: ["wake": "1"], rawFlags: 0
            )
            Task {
                await self?.registry.tickCount(.systemWake)
                await self?.bus?.publish(ev)
            }
        }
        sleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let ev = RawEvent(
                sourceType: .systemSleep, targetPath: nil, timestamp: now,
                payload: ["sleep": "1"], rawFlags: 0
            )
            Task {
                await self?.registry.tickCount(.systemSleep)
                await self?.bus?.publish(ev)
            }
        }
        mountObserver = nc.addObserver(forName: NSNotification.Name("NSWorkspaceDidMountNotification"), object: nil, queue: nil) { [weak self] note in
            let volumePath =
                (note.userInfo?["NSDevicePath"] as? String)
                ?? (note.userInfo?["NSVolumePath"] as? String)
            let now = UInt64(Date().timeIntervalSince1970 * 1000)
            let ev = RawEvent(
                sourceType: .fileModified, targetPath: volumePath, timestamp: now,
                payload: ["mount": "1"], rawFlags: 0
            )
            Task {
                await self?.registry.tickCount(.fileModified)
                await self?.bus?.publish(ev)
            }
        }
        FusionLog.source.info("nsworkspace source start (R8: mount observer registered)")
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
        let et: SystemEventType = snap.isLaunch ? .processLaunched : .processTerminated
        await registry.tickCount(et)
        await bus?.publish(
            RawEvent(
                sourceType: et,
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
        if let s = sleepObserver { nc.removeObserver(s) }
        if let m = mountObserver { nc.removeObserver(m) }
        observers.removeAll()
        wakeObserver = nil
        sleepObserver = nil
        mountObserver = nil
        FusionLog.source.info("nsworkspace source stop")
    }

}
