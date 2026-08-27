import Foundation

actor Lifecycle {
    private var shuttingDown = false
    private let registry: SourceRegistry
    private let ipc: IPCServer
    private let bus: EventBus
    private var esXpcServer: ESXPCServer?

    init(registry: SourceRegistry, ipc: IPCServer, bus: EventBus) {
        self.registry = registry
        self.ipc = ipc
        self.bus = bus
    }

    func trackESXPC(_ server: ESXPCServer) {
        self.esXpcServer = server
    }

    func isShuttingDown() -> Bool { shuttingDown }

    func gracefulShutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        FusionLog.lifecycle.info("graceful shutdown start")
        await bus.shutdown()
        await registry.stopAll()
        await esXpcServer?.stop()
        await ipc.stop()
        FusionLog.lifecycle.info("graceful shutdown done")
    }
}

enum LifecycleHandle {
    nonisolated(unsafe) static var shared: Lifecycle?

    static func installSignals() {
        signal(SIGTERM) { _ in
            guard let lc = LifecycleHandle.shared else { return }
            Task { await lc.gracefulShutdown() }
        }
        signal(SIGINT) { _ in
            guard let lc = LifecycleHandle.shared else { return }
            Task { await lc.gracefulShutdown() }
        }
        signal(SIGPIPE, SIG_IGN)
        FusionLog.lifecycle.info("signal handlers installed (SIGTERM/SIGINT)")
    }
}
