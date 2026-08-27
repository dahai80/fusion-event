import Foundation

struct LoggedEvent: Codable, Sendable {
    let event: SystemEvent
    let matchedRules: [String]
    let triggerId: String?
    let taskId: String?
    let idempotencyKey: String?
    let submittedAt: UInt64?
}

actor EventLog {
    private let logPath: String
    private let maxBytes: Int64 = 10 * 1024 * 1024
    private let maxArchives = 5
    private let queue = DispatchQueue(label: "fusion-event.eventlog")

    init(logPath: String) {
        self.logPath = logPath
    }

    func append(_ entry: LoggedEvent) {
        let path = self.logPath
        let maxB = self.maxBytes
        let maxA = self.maxArchives
        queue.sync {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            guard var data = try? enc.encode(entry) else { return }
            data.append(0x0A)
            Self.rotateIfNeeded(path: path, maxBytes: maxB, maxArchives: maxA)
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    func recordTrigger(triggerId: String, taskId: String?, idempotencyKey: String?, event: SystemEvent, matchedRules: [String]) {
        let entry = LoggedEvent(
            event: event,
            matchedRules: matchedRules,
            triggerId: triggerId,
            taskId: taskId,
            idempotencyKey: idempotencyKey,
            submittedAt: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        append(entry)
    }

    func replay(sinceTs: UInt64, limit: Int) -> [LoggedEvent] {
        let path = self.logPath
        var out: [LoggedEvent] = []
        queue.sync {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            let lines = data.split(separator: 0x0A)
            let dec = JSONDecoder()
            for line in lines.reversed() {
                guard let entry = try? dec.decode(LoggedEvent.self, from: Data(line)) else { continue }
                if entry.event.timestamp < sinceTs { continue }
                out.append(entry)
                if out.count >= limit { break }
            }
            out.reverse()
        }
        return out
    }

    func recentDebounceWindow(withinSec: UInt64) -> [String: UInt64] {
        let path = self.logPath
        var window: [String: UInt64] = [:]
        queue.sync {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            let lines = data.split(separator: 0x0A)
            let dec = JSONDecoder()
            let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
            let cutoffMs = nowMs > (withinSec * 1000) ? nowMs - (withinSec * 1000) : 0
            for line in lines {
                guard let entry = try? dec.decode(LoggedEvent.self, from: Data(line)) else { continue }
                guard !entry.matchedRules.isEmpty, entry.event.timestamp >= cutoffMs else { continue }
                for ruleName in entry.matchedRules {
                    let ts = entry.event.timestamp
                    if window[ruleName, default: 0] < ts { window[ruleName] = ts }
                }
            }
        }
        return window
    }

    private static func rotateIfNeeded(path: String, maxBytes: Int64, maxArchives: Int) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64, size > maxBytes else { return }
        for i in stride(from: maxArchives - 1, through: 1, by: -1) {
            let src = "\(path).\(i)"
            let dst = "\(path).\(i + 1)"
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.removeItem(atPath: dst)
                try? FileManager.default.moveItem(atPath: src, toPath: dst)
            }
        }
        try? FileManager.default.moveItem(atPath: path, toPath: "\(path).1")
        FusionLog.persist.info("eventlog rotate \(path, privacy: .public)")
    }
}
