import Foundation
import os

actor Lifecycle {
    private var shuttingDown = false
    private let registry: SourceRegistry
    private let ipc: IPCServer
    private let bus: EventBus
    private let dispatcher: Dispatcher
    private let shutdownTimeoutSec: Int
    private var esXpcServer: ESXPCServer?

    init(registry: SourceRegistry, ipc: IPCServer, bus: EventBus, dispatcher: Dispatcher, shutdownTimeoutSec: Int = 10) {
        self.registry = registry
        self.ipc = ipc
        self.bus = bus
        self.dispatcher = dispatcher
        self.shutdownTimeoutSec = shutdownTimeoutSec
    }

    func trackESXPC(_ server: ESXPCServer) {
        self.esXpcServer = server
    }

    func isShuttingDown() -> Bool { shuttingDown }

    func gracefulShutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        FusionLog.lifecycle.info("graceful shutdown start (timeout=\(self.shutdownTimeoutSec)s, R10)")
        await bus.shutdown()
        await dispatcher.drainForShutdown(timeoutSec: shutdownTimeoutSec)
        await registry.stopAll()
        await esXpcServer?.stop()
        await ipc.stop()
        FusionLog.lifecycle.info("graceful shutdown done")
    }
}

final class LifecycleHandle: @unchecked Sendable {
    private var shared: Lifecycle?
    private var lock = os_unfair_lock()
    private var termSource: DispatchSourceSignal?
    private var intSource: DispatchSourceSignal?

    private init() {}

    static let instance = LifecycleHandle()

    static func setShared(_ lc: Lifecycle) {
        instance.setSharedInternal(lc)
    }

    private func setSharedInternal(_ lc: Lifecycle) {
        os_unfair_lock_lock(&lock)
        shared = lc
        os_unfair_lock_unlock(&lock)
    }

    private func getShared() -> Lifecycle? {
        os_unfair_lock_lock(&lock)
        let lc = shared
        os_unfair_lock_unlock(&lock)
        return lc
    }

    func installSignals() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { [weak self] in
            guard let lc = self?.getShared() else { return }
            FusionLog.lifecycle.notice("SIGTERM received")
            Task { await lc.gracefulShutdown() }
        }
        term.resume()
        termSource = term

        let int = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        int.setEventHandler { [weak self] in
            guard let lc = self?.getShared() else { return }
            FusionLog.lifecycle.notice("SIGINT received")
            Task { await lc.gracefulShutdown() }
        }
        int.resume()
        intSource = int

        FusionLog.lifecycle.info("signal handlers installed (SIGTERM/SIGINT via DispatchSource, L1)")
    }
}
