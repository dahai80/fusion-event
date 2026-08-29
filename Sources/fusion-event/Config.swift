import Foundation

struct FusionEventConfig: Codable, Sendable {
    var sockPath: String
    var guardSock: String
    var memorySock: String
    var studioSock: String
    var dataDir: String
    var nodeId: String
    var contextCacheTtlSec: Int
    var contextCacheMaxEntries: Int
    var heartbeatIntervalSec: Int
    var heartbeatDeadSec: Int
    var tokenBucketMax: Int
    var dispatchQueueMax: Int
    var outboundTimeoutGuard: Int
    var outboundTimeoutMemory: Int
    var outboundTimeoutDispatch: Int
    var fseventsWatchPaths: [String]
    var fseventsLatencySec: Double
    var pasteboardPollSec: Int
    var shutdownTimeoutSec: Int
    var walCheckpointIntervalSec: Int
    var esEnabled: Bool
    var esXpcEnabled: Bool

    static let `default` = FusionEventConfig(
        sockPath: ProcessInfo.processInfo.environment["FUSION_EVENT_SOCK"] ?? "/tmp/fusion-event.sock",
        guardSock: ProcessInfo.processInfo.environment["FUSION_GUARD_SOCK"] ?? "/tmp/fusion-guard.sock",
        memorySock: ProcessInfo.processInfo.environment["FUSION_MEMORY_SOCK"] ?? "\(NSHomeDirectory())/.fusion-memory/fusion-memory.sock",
        studioSock: ProcessInfo.processInfo.environment["FUSION_STUDIO_SOCK"] ?? "/tmp/fusion-studio.sock",
        dataDir: ProcessInfo.processInfo.environment["FUSION_EVENT_DATA"] ?? "\(NSHomeDirectory())/.fusion-event",
        nodeId: ProcessInfo.processInfo.environment["FUSION_NODE_ID"] ?? "auto",
        contextCacheTtlSec: 60,
        contextCacheMaxEntries: 5000,
        heartbeatIntervalSec: 15,
        heartbeatDeadSec: 45,
        tokenBucketMax: 16,
        dispatchQueueMax: 512,
        outboundTimeoutGuard: 2,
        outboundTimeoutMemory: 3,
        outboundTimeoutDispatch: 5,
        fseventsWatchPaths: [],
        fseventsLatencySec: 0.3,
        pasteboardPollSec: 1,
        shutdownTimeoutSec: 10,
        walCheckpointIntervalSec: 300,
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
                try out.write(to: URL(fileURLWithPath: path), options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                FusionLog.lifecycle.info("config written to \(path, privacy: .public) mode=0600 (S1)")
            }
        } catch {
            FusionLog.lifecycle.error("config load fail \(error.localizedDescription, privacy: .public), use default")
        }
        cfg.nodeId = resolveNodeId(dataDir: cfg.dataDir, declared: cfg.nodeId)
        if cfg.fseventsWatchPaths.isEmpty {
            FusionLog.lifecycle.notice("fsevents watch paths empty (A2/R1): file events disabled until rule.add path_pattern drives registration or watch_paths configured; avoid whole-home-dir flood")
        }
        return cfg
    }

    static func resolveNodeId(dataDir: String, declared: String) -> String {
        if declared != "auto" && !declared.isEmpty {
            return declared
        }
        let idPath = "\(dataDir)/node.id"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: URL(fileURLWithPath: idPath)),
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty
        {
            return s
        }
        let newId = "node-" + UUID().uuidString.prefix(8)
        try? newId.data(using: .utf8)?.write(to: URL(fileURLWithPath: idPath), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: idPath)
        FusionLog.lifecycle.info("nodeId generated and persisted \(newId, privacy: .public) at \(idPath, privacy: .public) mode=0600 (A2: stable unique identity, not hostname; S1)")
        return String(newId)
    }
}
