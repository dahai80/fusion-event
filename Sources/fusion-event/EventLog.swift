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
    private var fileHandle: FileHandle?
    private var writtenBytes: Int64 = 0

    init(logPath: String) {
        self.logPath = logPath
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        fileHandle?.seekToEndOfFile()
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath)
        writtenBytes = (attrs?[.size] as? Int64) ?? 0
    }

    private func openHandle() {
        fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        fileHandle?.seekToEndOfFile()
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath)
        writtenBytes = (attrs?[.size] as? Int64) ?? 0
    }

    func append(_ entry: LoggedEvent) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard var data = try? enc.encode(entry) else { return }
        data.append(0x0A)
        if writtenBytes + Int64(data.count) > maxBytes {
            rotate()
        }
        if fileHandle == nil { openHandle() }
        if fileHandle == nil {
            try? data.write(to: URL(fileURLWithPath: logPath), options: [.atomic])
            writtenBytes += Int64(data.count)
            return
        }
        fileHandle?.write(data)
        try? fileHandle?.synchronize()
        writtenBytes += Int64(data.count)
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
        var out: [LoggedEvent] = []
        let dec = JSONDecoder()
        var collected: [LoggedEvent] = []
        let chunkSize = 8192
        let files = readableLogFiles()
        for f in files {
            guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: f)) else {
                FusionLog.persist.error("eventlog replay open fail \(f, privacy: .public) (R9: no silent empty)")
                continue
            }
            var pending = Data()
            while true {
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    if !pending.isEmpty, let entry = try? dec.decode(LoggedEvent.self, from: pending) {
                        if entry.event.timestamp >= sinceTs { collected.append(entry) }
                    }
                    break
                }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending.subdata(in: 0..<nl)
                    pending.removeSubrange(0...nl)
                    guard !line.isEmpty, let entry = try? dec.decode(LoggedEvent.self, from: line) else { continue }
                    if entry.event.timestamp >= sinceTs { collected.append(entry) }
                }
            }
            try? fh.close()
        }
        for entry in collected.reversed() {
            out.append(entry)
            if out.count >= limit { break }
        }
        out.reverse()
        return out
    }

    private func readableLogFiles() -> [String] {
        var files = [logPath]
        for i in 1...maxArchives {
            let archived = "\(logPath).\(i)"
            if FileManager.default.fileExists(atPath: archived) {
                files.append(archived)
            }
        }
        return files
    }

    func recentDebounceWindow(withinSec: UInt64) -> [String: UInt64] {
        var window: [String: UInt64] = [:]
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let cutoffMs = nowMs > (withinSec * 1000) ? nowMs - (withinSec * 1000) : 0
        let dec = JSONDecoder()
        let files = readableLogFiles().reversed()
        var stopAll = false
        for f in files {
            if stopAll { break }
            guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: f)) else { continue }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: f)[.size] as? Int64) ?? 0
            var offset = max(0, fileSize)
            let chunkSize: Int64 = 65536
            var buffer = Data()
            var stop = false
            while offset > 0 && !stop {
                let readLen = min(chunkSize, offset)
                offset -= readLen
                try? fh.seek(toOffset: UInt64(offset))
                let chunk = fh.readData(ofLength: Int(readLen))
                buffer = chunk + buffer
                while let nl = buffer.lastIndex(of: 0x0A) {
                    let line = buffer.subdata(in: (nl + 1)..<buffer.count)
                    buffer.removeSubrange(nl..<buffer.count)
                    guard !line.isEmpty, let entry = try? dec.decode(LoggedEvent.self, from: line) else { continue }
                    if entry.event.timestamp < cutoffMs { stop = true; break }
                    guard !entry.matchedRules.isEmpty else { continue }
                    for ruleName in entry.matchedRules {
                        let ts = entry.event.timestamp
                        if window[ruleName, default: 0] < ts { window[ruleName] = ts }
                    }
                }
            }
            if !stop, !buffer.isEmpty {
                if let entry = try? dec.decode(LoggedEvent.self, from: buffer) {
                    if entry.event.timestamp < cutoffMs { stop = true }
                    else if !entry.matchedRules.isEmpty {
                        for ruleName in entry.matchedRules {
                            let ts = entry.event.timestamp
                            if window[ruleName, default: 0] < ts { window[ruleName] = ts }
                        }
                    }
                }
            }
            try? fh.close()
            if stop { stopAll = true }
        }
        return window
    }

    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil
        for i in stride(from: maxArchives - 1, through: 1, by: -1) {
            let src = "\(logPath).\(i)"
            let dst = "\(logPath).\(i + 1)"
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.removeItem(atPath: dst)
                try? FileManager.default.moveItem(atPath: src, toPath: dst)
            }
        }
        try? FileManager.default.moveItem(atPath: logPath, toPath: "\(logPath).1")
        FileManager.default.createFile(atPath: logPath, contents: nil)
        writtenBytes = 0
        openHandle()
        FusionLog.persist.info("eventlog rotate \(self.logPath, privacy: .public)")
    }
}
