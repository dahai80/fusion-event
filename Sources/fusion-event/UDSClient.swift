import Foundation

enum UDSClientError: Error, Equatable {
    case connectionFailed
    case timeout
    case ioError(String)
}

actor UDSClient {
    private let sockPath: String
    private let timeoutSec: Int
    private var fd: Int32 = -1
    private var poisoned: Bool = false

    init(sockPath: String, timeoutSec: Int = 5) {
        self.sockPath = sockPath
        self.timeoutSec = max(1, timeoutSec)
    }

    func connect() throws {
        if fd >= 0 { return }
        if poisoned {
            throw UDSClientError.ioError("connection poisoned, recreate client")
        }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSClientError.ioError("socket create fail") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = sockPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let src = pathBytes.withUnsafeBytes { Data($0) }
            let count = min(src.count, dst.count - 1)
            dst.copyBytes(from: src.prefix(count))
        }
        var connected = false
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connected = Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if !connected {
            Darwin.close(fd); fd = -1
            throw UDSClientError.connectionFailed
        }
        var nosig: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeoutSec), tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func call(_ req: RPCRequest) async throws -> RPCResponse {
        try connect()
        var data = RPCCodec.encode(req)
        data.append(0x0A)
        do {
            try writeAll(data)
            let line = try readLine()
            guard let resp = try? JSONDecoder().decode(RPCResponse.self, from: line) else {
                poison("decode response fail")
                throw UDSClientError.ioError("decode response fail")
            }
            return resp
        } catch let err as UDSClientError {
            poison("call io fail \(err)")
            throw err
        }
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress?.advanced(by: sent) else { return -1 }
                return Darwin.send(fd, base, data.count - sent, 0)
            }
            if n <= 0 {
                if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw UDSClientError.timeout
                }
                throw UDSClientError.ioError("send fail errno=\(errno)")
            }
            sent += n
        }
    }

    private func readLine() throws -> Data {
        var buf = Data()
        buf.reserveCapacity(512)
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { chunk.deallocate() }
        while true {
            let n = Darwin.recv(fd, chunk, 4096, 0)
            if n <= 0 {
                if n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    throw UDSClientError.timeout
                }
                throw UDSClientError.ioError("recv fail errno=\(errno)")
            }
            let got = UnsafeBufferPointer(start: chunk, count: n)
            var foundNewline = false
            for i in 0..<n {
                if got[i] == 0x0A {
                    let prefix = UnsafeBufferPointer(start: chunk, count: i)
                    buf.append(prefix)
                    foundNewline = true
                    break
                }
            }
            if foundNewline {
                if buf.count > 1_048_576 {
                    throw UDSClientError.ioError("response too large >1MB")
                }
                return buf
            }
            buf.append(UnsafeBufferPointer(start: chunk, count: n))
            if buf.count > 1_048_576 {
                throw UDSClientError.ioError("response too large >1MB")
            }
        }
    }

    private func poison(_ reason: String) {
        FusionLog.bridge.error("udsclient poisoned: \(reason, privacy: .public)")
        poisoned = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        poisoned = false
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }
}

func withTimeout<T: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            throw UDSClientError.timeout
        }
        do {
            guard let result = try await group.next() else { throw UDSClientError.timeout }
            group.cancelAll()
            return result
        } catch {
            group.cancelAll()
            throw error
        }
    }
}
