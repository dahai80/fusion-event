import Foundation

struct FusionEventConfig: Codable, Sendable {
    var sockPath: String
    var guardSock: String
    var memorySock: String
    var studioSock: String
    var dataDir: String
    var nodeId: String
    var contextCacheTtlSec: Int
    var heartbeatIntervalSec: Int
    var heartbeatDeadSec: Int
    var tokenBucketMax: Int
    var outboundTimeoutGuard: Int
    var outboundTimeoutMemory: Int
    var outboundTimeoutDispatch: Int
    var fseventsRoot: String
    var esEnabled: Bool
    var esXpcEnabled: Bool

    static let `default` = FusionEventConfig(
        sockPath: ProcessInfo.processInfo.environment["FUSION_EVENT_SOCK"] ?? "/tmp/fusion-event.sock",
        guardSock: ProcessInfo.processInfo.environment["FUSION_GUARD_SOCK"] ?? "/tmp/fusion-guard.sock",
        memorySock: ProcessInfo.processInfo.environment["FUSION_MEMORY_SOCK"] ?? "/tmp/fusion-memory.sock",
        studioSock: ProcessInfo.processInfo.environment["FUSION_STUDIO_SOCK"] ?? "/tmp/fusion-studio.sock",
        dataDir: ProcessInfo.processInfo.environment["FUSION_EVENT_DATA"] ?? "\(NSHomeDirectory())/.fusion-event",
        nodeId: ProcessInfo.processInfo.environment["FUSION_NODE_ID"] ?? Host.current().localizedName ?? "local-node",
        contextCacheTtlSec: 60,
        heartbeatIntervalSec: 15,
        heartbeatDeadSec: 45,
        tokenBucketMax: 5,
        outboundTimeoutGuard: 2,
        outboundTimeoutMemory: 3,
        outboundTimeoutDispatch: 5,
        fseventsRoot: NSHomeDirectory(),
        esEnabled: ProcessInfo.processInfo.environment["FUSION_EVENT_ES_ENABLED"] == "1",
        esXpcEnabled: ProcessInfo.processInfo.environment["FUSION_EVENT_ES_XPC_ENABLED"] == "1"
    )

    static func load(dataDir: String) -> FusionEventConfig {
        let path = "\(dataDir)/config.json"
        var cfg = FusionEventConfig.default
        cfg.dataDir = dataDir
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: path) {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                cfg = try JSONDecoder().decode(FusionEventConfig.self, from: data)
                if ProcessInfo.processInfo.environment["FUSION_EVENT_SOCK"] != nil {
                    cfg.sockPath = ProcessInfo.processInfo.environment["FUSION_EVENT_SOCK"]!
                }
                if ProcessInfo.processInfo.environment["FUSION_GUARD_SOCK"] != nil {
                    cfg.guardSock = ProcessInfo.processInfo.environment["FUSION_GUARD_SOCK"]!
                }
                if ProcessInfo.processInfo.environment["FUSION_MEMORY_SOCK"] != nil {
                    cfg.memorySock = ProcessInfo.processInfo.environment["FUSION_MEMORY_SOCK"]!
                }
                if ProcessInfo.processInfo.environment["FUSION_STUDIO_SOCK"] != nil {
                    cfg.studioSock = ProcessInfo.processInfo.environment["FUSION_STUDIO_SOCK"]!
                }
            } else {
                cfg.dataDir = dataDir
                let parent = (path as NSString).deletingLastPathComponent
                try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                let out = try enc.encode(cfg)
                try out.write(to: URL(fileURLWithPath: path))
                FusionLog.lifecycle.info("config written to \(path, privacy: .public)")
            }
        } catch {
            FusionLog.lifecycle.error("config load fail \(error.localizedDescription, privacy: .public), use default")
        }
        return cfg
    }
}
