import Foundation

public actor ESXPCServer {
    private weak var bus: EventBus?
    private let registry: SourceRegistry
    private var listener: NSXPCListener?
    private var endpoint: NSXPCListenerEndpoint?
    private var enabled = false

    public init(bus: EventBus, registry: SourceRegistry) {
        self.bus = bus
        self.registry = registry
    }

    public func startAnonymous() -> NSXPCListenerEndpoint? {
        let listener = NSXPCListener.anonymous()
        let delegate = ESXPCDelegate()
        delegate.bus = bus
        delegate.registry = registry
        listener.delegate = delegate
        objc_setAssociatedObject(listener, "fe.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
        listener.resume()
        self.listener = listener
        self.endpoint = listener.endpoint
        enabled = true
        FusionLog.source.info("es-xpc server anonymous listener resume")
        return listener.endpoint
    }

    public func stop() {
        listener?.invalidate()
        listener = nil
        endpoint = nil
        enabled = false
        FusionLog.source.info("es-xpc server stop")
    }

    public func isEnabled() -> Bool { enabled }

    public func endpointRef() -> NSXPCListenerEndpoint? { endpoint }
}

final class ESXPCDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    weak var bus: EventBus?
    weak var registry: SourceRegistry?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ESXPCProtocol.self)
        let handler = ESXPCHandler(bus: bus, registry: registry)
        newConnection.exportedObject = handler
        newConnection.resume()
        FusionLog.source.info("es-xpc accept connection")
        return true
    }
}

final class ESXPCHandler: NSObject, ESXPCProtocol, @unchecked Sendable {
    weak var bus: EventBus?
    weak var registry: SourceRegistry?

    init(bus: EventBus?, registry: SourceRegistry?) {
        self.bus = bus
        self.registry = registry
    }

    func deliverEvent(_ payload: NSData) {
        guard let snap = try? ESSnapshotXPC.decode(payload as Data) else {
            FusionLog.source.error("es-xpc decode fail, drop")
            return
        }
        FusionLog.source.info("es-xpc deliver pid=\(snap.pid) action=\(snap.action, privacy: .public)")
        Task { [weak bus, weak registry] in
            guard let bus, let registry else { return }
            await registry.tickCount(.processTerminated)
            await bus.publish(RawEvent(
                sourceType: .processTerminated,
                targetPath: snap.execPath,
                timestamp: snap.timestamp,
                payload: [
                    "pid": String(snap.pid),
                    "event": snap.action,
                    "source": snap.source
                ],
                rawFlags: 0
            ))
        }
    }
}
