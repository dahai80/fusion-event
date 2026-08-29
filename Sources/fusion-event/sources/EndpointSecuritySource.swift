import Foundation
import EndpointSecurity

public actor EndpointSecuritySource: EventSource {
    public let sourceType: SystemEventType = .processTerminated
    private weak var bus: EventBus?
    private let registry: SourceRegistry
    private var client: OpaquePointer?
    private var infoPtr: UnsafeMutableRawPointer?
    private var enabled: Bool = false

    public init(bus: EventBus, registry: SourceRegistry) {
        self.bus = bus
        self.registry = registry
    }

    struct ESSnap: Sendable {
        let pid: Int32
        let execPath: String?
        let action: String
        let timestamp: UInt64
    }

    public func start() async {
        guard client == nil else {
            FusionLog.source.notice("endpoint-security already started, skip duplicate (F-1: start idempotent)")
            return
        }
        let mePtr = Unmanaged.passRetained(self).toOpaque()
        self.infoPtr = mePtr
        var rawClient: OpaquePointer? = nil
        let handler: @convention(block) (OpaquePointer, UnsafePointer<es_message_t>) -> Void = { _, msgPtr in
            let me = Unmanaged<EndpointSecuritySource>.fromOpaque(mePtr).takeUnretainedValue()
            guard let snap = EndpointSecuritySource.extract(msgPtr) else { return }
            Task { await me.publish(snap) }
        }
        let result = es_new_client(&rawClient, handler)
        switch result {
        case ES_NEW_CLIENT_RESULT_SUCCESS:
            guard let rawClient else {
                FusionLog.source.error("es new_client success but nil client")
                releaseRetainOnFailure()
                return
            }
            client = rawClient
            let events: [es_event_type_t] = [
                ES_EVENT_TYPE_NOTIFY_EXEC,
                ES_EVENT_TYPE_NOTIFY_EXIT,
                ES_EVENT_TYPE_NOTIFY_FORK
            ]
            let sub = events.withUnsafeBufferPointer { buf in
                es_subscribe(rawClient, buf.baseAddress!, UInt32(buf.count))
            }
            if sub != ES_RETURN_SUCCESS {
                FusionLog.source.error("es subscribe fail rc=\(sub.rawValue, privacy: .public)")
                es_delete_client(rawClient)
                client = nil
                enabled = false
                releaseRetainOnFailure()
                return
            }
            enabled = true
            FusionLog.source.info("endpoint-security source start (exec/exit/fork)")
        case ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED:
            enabled = false
            FusionLog.source.notice("es newClientFailed not entitled, degrade to NSWorkspace (M3)")
            releaseRetainOnFailure()
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PERMITTED:
            enabled = false
            FusionLog.source.notice("es newClientFailed not permitted (TCC), degrade to NSWorkspace (M3)")
            releaseRetainOnFailure()
        case ES_NEW_CLIENT_RESULT_ERR_NOT_PRIVILEGED:
            enabled = false
            FusionLog.source.notice("es newClientFailed not root, degrade to NSWorkspace (M3)")
            releaseRetainOnFailure()
        default:
            enabled = false
            FusionLog.source.error("es new_client fail rc=\(result.rawValue, privacy: .public), degrade to NSWorkspace (M3)")
            releaseRetainOnFailure()
        }
    }

    private func releaseRetainOnFailure() {
        if let ptr = infoPtr {
            Unmanaged<EndpointSecuritySource>.fromOpaque(ptr).release()
            infoPtr = nil
        }
    }

    public func stop() async {
        if let client {
            es_delete_client(client)
            self.client = nil
            FusionLog.source.info("endpoint-security source stop")
        }
        if let ptr = infoPtr {
            Unmanaged<EndpointSecuritySource>.fromOpaque(ptr).release()
            infoPtr = nil
        }
        enabled = false
    }

    public func isEnabled() -> Bool { enabled }

    nonisolated static func extract(_ msgPtr: UnsafePointer<es_message_t>) -> ESSnap? {
        let msg = msgPtr.pointee
        guard msg.version >= 1 else {
            FusionLog.source.error("es message version \(msg.version) unsupported, skip (F-5: version guard)")
            return nil
        }
        let eventType = msg.event_type
        let action: String
        switch eventType {
        case ES_EVENT_TYPE_NOTIFY_EXEC:
            action = "exec"
        case ES_EVENT_TYPE_NOTIFY_EXIT:
            action = "exit"
        case ES_EVENT_TYPE_NOTIFY_FORK:
            action = "fork"
        default:
            return nil
        }
        let processPtr = msg.process
        guard let processPtrOpt: UnsafeMutablePointer<es_process_t>? = processPtr, processPtrOpt != nil else {
            FusionLog.source.error("es extract process nil, skip")
            return nil
        }
        let process = processPtr.pointee
        let pid = audit_token_to_pid(process.audit_token)
        let execPath: String? = {
            let execPtr = process.executable
            guard let execPtrOpt: UnsafeMutablePointer<es_file_t>? = execPtr, execPtrOpt != nil else { return nil }
            let exec = execPtr.pointee
            let tok = exec.path
            guard tok.length > 0 else { return nil }
            guard let dataPtr = tok.data else { return nil }
            let len = Int(tok.length)
            return dataPtr.withMemoryRebound(to: UInt8.self, capacity: len) { ptr in
                String(bytes: UnsafeBufferPointer(start: ptr, count: len), encoding: .utf8)
            }
        }()
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return ESSnap(pid: pid, execPath: execPath, action: action, timestamp: now)
    }

    private func publish(_ snap: ESSnap) async {
        guard enabled else { return }
        await registry.tickCount(.processTerminated)
        await bus?.publish(
            RawEvent(
                sourceType: .processTerminated,
                targetPath: snap.execPath,
                timestamp: snap.timestamp,
                payload: [
                    "pid": String(snap.pid),
                    "event": snap.action,
                    "source": "endpoint-security"
                ],
                rawFlags: 0
            ))
    }
}
