import Foundation

public actor ESXPCMockClient {
    private var connection: NSXPCConnection?
    private let endpoint: NSXPCListenerEndpoint

    public init(endpoint: NSXPCListenerEndpoint) {
        self.endpoint = endpoint
    }

    public func connect() -> Bool {
        let conn = NSXPCConnection(listenerEndpoint: endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: ESXPCProtocol.self)
        conn.resume()
        connection = conn
        FusionLog.source.info("es-xpc mock client connect")
        return true
    }

    public func deliver(_ snap: ESSnapshotXPC) async -> Bool {
        guard let connection else { return false }
        guard let proxy = connection.remoteObjectProxy as? ESXPCProtocol else { return false }
        guard let data = try? snap.encoded() else { return false }
        proxy.deliverEvent(data as NSData)
        return true
    }

    public func close() {
        connection?.invalidate()
        connection = nil
    }
}
