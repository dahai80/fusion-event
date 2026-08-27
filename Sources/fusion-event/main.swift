import Foundation

let dataDir = ProcessInfo.processInfo.environment["FUSION_EVENT_DATA"] ?? "\(NSHomeDirectory())/.fusion-event"
let config = FusionEventConfig.load(dataDir: dataDir)
FusionLog.lifecycle.info("fusion-event starting, node=\(config.nodeId, privacy: .public), sock=\(config.sockPath, privacy: .public)")

let store = RuleStore(dbPath: "\(dataDir)/rules.db", nodeId: config.nodeId)
let ruleEngine = RuleEngine(store: store, nodeId: config.nodeId)

let eventLog = EventLog(logPath: "\(dataDir)/events.log")
await ruleEngine.setEventLog(eventLog)
await ruleEngine.loadFromStore()
let dispatcher = Dispatcher(
    sockPath: config.studioSock,
    timeoutSec: config.outboundTimeoutDispatch,
    tokenBucketMax: config.tokenBucketMax,
    eventLog: eventLog
)
let auditBridge = AuditBridge(sockPath: config.guardSock, timeoutSec: config.outboundTimeoutGuard)
let contextBridge = ContextBridge(
    sockPath: config.memorySock,
    timeoutSec: config.outboundTimeoutMemory,
    ttlSec: config.contextCacheTtlSec
)
await dispatcher.setBridges(audit: auditBridge, context: contextBridge)
await ruleEngine.setSink(dispatcher)

let bus = EventBus(ruleEngine: ruleEngine)
let registry = SourceRegistry()
await registry.register(FSEventsSource(rootPath: config.fseventsRoot, bus: bus, registry: registry))
await registry.register(NSWorkspaceSource(bus: bus, registry: registry))
await registry.register(NetworkSource(bus: bus, registry: registry))
await registry.register(PasteboardSource(bus: bus, registry: registry))
if config.esEnabled {
    await registry.register(EndpointSecuritySource(bus: bus, registry: registry))
    FusionLog.lifecycle.info("endpoint-security enabled (M3), es_new_client will degrade to NSWorkspace if unentitled")
}
let methods = RPCMethods(
    ruleEngine: ruleEngine, eventLog: eventLog,
    dispatcher: dispatcher, registry: registry, config: config
)
let ipc = IPCServer(
    sockPath: config.sockPath, methods: methods, bus: bus,
    heartbeatSec: config.heartbeatIntervalSec, deadSec: config.heartbeatDeadSec
)
let lifecycle = Lifecycle(registry: registry, ipc: ipc, bus: bus, dispatcher: dispatcher)

LifecycleHandle.setShared(lifecycle)
LifecycleHandle.instance.installSignals()

if config.esXpcEnabled {
    let esXpcServer = ESXPCServer(bus: bus, registry: registry)
    if await esXpcServer.startAnonymous() != nil {
        FusionLog.lifecycle.info("es-xpc server ready, endpoint=\(String(describing: esXpcServer), privacy: .public) (Phase-2 L1: contract skeleton; real ES extension acquires endpoint via launchd/xpc bootstrap, not file — NSXPCListenerEndpoint only encodable by NSXPCCoder)")
    } else {
        FusionLog.lifecycle.error("es-xpc server start fail")
    }
    await lifecycle.trackESXPC(esXpcServer)
}

await ipc.start()
await registry.startAll()

FusionLog.lifecycle.info("fusion-event ready")
while await !lifecycle.isShuttingDown() {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
