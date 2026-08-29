import Foundation
import os.lock
@testable import fusion_event

final class MockStudio: @unchecked Sendable {
    private let sockPath: String
    private var listenFd: Int32 = -1
    private var serverTask: Task<Void, Never>?
    private let connLock = OSAllocatedUnfairLock(initialState: [Int32]())
    private let bodyLock = OSAllocatedUnfairLock(initialState: [String]())

    init(sockPath: String) {
        self.sockPath = sockPath
    }

    var lastBodies: [String] {
        bodyLock.withLock { $0 }
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
        serverTask = Task { [weak self] in
            while !Task.isCancelled {
                let cfd = Darwin.accept(lfd, nil, nil)
                if cfd < 0 { break }
                self?.connLock.withLock { $0.append(cfd) }
                Task { self?.handleConn(fd: cfd) }
            }
        }
    }

    private nonisolated func handleConn(fd: Int32) {
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
            if let s = String(data: buf, encoding: .utf8) {
                bodyLock.withLock { $0.append(s) }
            }
            let idStr = extractId(buf)
            let resp = #"{"jsonrpc":"2.0","id":\#(idStr),"result":{"task":{"task_id":"t1"}}}"#
            let respData = (resp + "\n").data(using: .utf8) ?? Data()
            _ = respData.withUnsafeBytes { b -> Int in
                guard let base = b.baseAddress else { return -1 }
                return Darwin.send(fd, base, respData.count, 0)
            }
        }
    }

    private nonisolated func extractId(_ data: Data) -> String {
        guard let s = String(data: data, encoding: .utf8),
            let r = s.range(of: "\"id\":")
        else { return "1" }
        let rest = s[r.upperBound...]
        let num = rest.prefix { $0.isNumber }
        if !num.isEmpty { return String(num) }
        if let q = rest.first, q == "\"" {
            let after = rest.dropFirst()
            let str = after.prefix { $0 != "\"" }
            return "\"\(str)\""
        }
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
