import XCTest
import os.lock
@testable import fusion_event

// Verifies ContextBridge contract against fusion-memory retrieve_context_contract
// (issue #4 CLOSED: upstream added contract; direction B socket path + response parse).
// Mock memory server returns {context, memory_ids, cache_hit}; asserts parse + LRU cache.
// NOT degrade-path: real socket + real response parse.

private final class MockMemory: @unchecked Sendable {
    private let sockPath: String
    private var listenFd: Int32 = -1
    private var serverTask: Task<Void, Never>?
    private var respJSON: String
    private let connLock = OSAllocatedUnfairLock(initialState: [Int32]())

    init(sockPath: String, respJSON: String) {
        self.sockPath = sockPath
        self.respJSON = respJSON
    }

    func start() throws {
        unlink(sockPath)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let count = min(pathBytes.count - 1, dst.count - 1)
            for i in 0..<count { dst[i] = UInt8(bitPattern: pathBytes[i]) }
        }
        var bound = false
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bound = Darwin.bind(listenFd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard bound else { Darwin.close(listenFd); listenFd = -1; throw POSIXError(.EIO) }
        Darwin.listen(listenFd, 16)
        let lfd = listenFd
        let r = respJSON
        serverTask = Task { [weak self] in
            while !Task.isCancelled {
                let cfd = Darwin.accept(lfd, nil, nil)
                if cfd < 0 { break }
                self?.connLock.withLock { $0.append(cfd) }
                Task { self?.handleConn(fd: cfd, resp: r) }
            }
        }
    }

    private nonisolated func handleConn(fd: Int32, resp: String) {
        var nosig: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var byte: [UInt8] = [0]
        while true {
            var buf = Data()
            var gotLine = false
            while !gotLine {
                let n = Darwin.recv(fd, &byte, 1, 0)
                if n <= 0 {
                    Darwin.close(fd)
                    self.connLock.withLock { $0.removeAll { $0 == fd } }
                    return
                }
                if byte[0] == 0x0A { gotLine = true } else { buf.append(byte[0]) }
            }
            let idStr = extractId(buf)
            let respLine = #"{"jsonrpc":"2.0","id":\#(idStr),"result":\#(resp)}"#
            let respData = (respLine + "\n").data(using: .utf8) ?? Data()
            _ = respData.withUnsafeBytes { b -> Int in
                guard let base = b.baseAddress else { return -1 }
                return Darwin.send(fd, base, respData.count, 0)
            }
        }
    }

    private nonisolated func extractId(_ data: Data) -> String {
        guard let s = String(data: data, encoding: .utf8),
              let r = s.range(of: "\"id\":") else { return "1" }
        let rest = s[r.upperBound...]
        let num = rest.prefix { $0.isNumber }
        if !num.isEmpty { return String(num) }
        return "1"
    }

    func stop() {
        serverTask?.cancel()
        if listenFd >= 0 { Darwin.close(listenFd); listenFd = -1 }
        let conns = connLock.withLock { fds -> [Int32] in
            let copy = fds
            fds.removeAll()
            return copy
        }
        for fd in conns { Darwin.close(fd) }
        unlink(sockPath)
    }
}

final class ContextBridgeTests: XCTestCase {
    private var tmpDir: String = ""

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "fe-ctx-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if !tmpDir.isEmpty {
            try? FileManager.default.removeItem(atPath: tmpDir)
        }
        super.tearDown()
    }

    private func makeSignal() -> TriggerSignal {
        let rule = EventRule(ruleName: "r1", eventType: .fileModified, pathPattern: "/x/*", debounceMs: 0, throttleMs: 0, targetAgent: "fusion-code", targetGraphId: nil, enabled: true, maxRetries: 0, requireGuard: false)
        let raw = RawEvent(sourceType: .fileModified, targetPath: "/x/a.swift", timestamp: 1000, payload: [:], rawFlags: 0)
        return Normalizer.normalize(event: raw, rule: rule, nodeId: "n1")
    }

    func testRetrieveContextParsesContractResponse() async throws {
        let r = #"{"context":"hist-block-1\n---\nhist-block-2","memory_ids":["m1","m2"],"cache_hit":false}"#
        let path = tmpDir + "mem.sock"
        let mock = MockMemory(sockPath: path, respJSON: r)
        try mock.start()
        defer { mock.stop() }
        let ctx = ContextBridge(sockPath: path, timeoutSec: 2, ttlSec: 60)
        let result = await ctx.retrieveContext(signal: makeSignal())
        XCTAssertTrue(result.context.contains("hist-block-1"), "context text must populate from memory retrieve_context contract")
        XCTAssertEqual(result.memoryIds, ["m1", "m2"])
        XCTAssertFalse(result.cacheHit)
        XCTAssertFalse(result.contextStale)
        await ctx.close()
    }

    func testRetrieveContextSecondCallHitsCache() async throws {
        let r = #"{"context":"cached-ctx","memory_ids":["m1"],"cache_hit":false}"#
        let path = tmpDir + "mem.sock"
        let mock = MockMemory(sockPath: path, respJSON: r)
        try mock.start()
        defer { mock.stop() }
        let ctx = ContextBridge(sockPath: path, timeoutSec: 2, ttlSec: 60)
        _ = await ctx.retrieveContext(signal: makeSignal())
        let result = await ctx.retrieveContext(signal: makeSignal())
        XCTAssertEqual(result.context, "cached-ctx", "second call same query bucket must hit LRU cache")
        await ctx.close()
    }

    func testRetrieveContextDegradesWhenMemoryAbsent() async throws {
        let ctx = ContextBridge(sockPath: tmpDir + "absent.sock", timeoutSec: 1, ttlSec: 60)
        let result = await ctx.retrieveContext(signal: makeSignal())
        XCTAssertEqual(result.context, "", "absent memory -> empty fallback, no crash")
        XCTAssertFalse(result.contextStale)
        await ctx.close()
    }
}
