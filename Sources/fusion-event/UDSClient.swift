import Foundation

enum UDSClientError: Error {
    case connectionFailed
    case timeout
    case ioError(String)
}

actor UDSClient {
    private let sockPath: String
    private var fd: Int32 = -1

    init(sockPath: String) {
        self.sockPath = sockPath
    }

    func connect() throws {
        if fd >= 0 { return }
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
    }

    func call(_ req: RPCRequest) async throws -> RPCResponse {
        try connect()
        var data = RPCCodec.encode(req)
        data.append(0x0A)
        try writeAll(data)
        let line = try readLine()
        guard let resp = try? JSONDecoder().decode(RPCResponse.self, from: line) else {
            throw UDSClientError.ioError("decode response fail")
        }
        return resp
    }

    private func writeAll(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress?.advanced(by: sent) else { return -1 }
                return Darwin.send(fd, base, data.count - sent, 0)
            }
            if n <= 0 { throw UDSClientError.ioError("send fail") }
            sent += n
        }
    }

    private func readLine() throws -> Data {
        var buf = Data()
        var byte: [UInt8] = [0]
        while true {
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n <= 0 { throw UDSClientError.ioError("recv fail") }
            if byte[0] == 0x0A { break }
            buf.append(byte[0])
        }
        return buf
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
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
        guard let result = try await group.next() else { throw UDSClientError.timeout }
        group.cancelAll()
        return result
    }
}
