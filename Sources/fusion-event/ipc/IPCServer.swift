import Foundation

actor IPCServer {
    private let sockPath: String
    private let allowedUid: uid_t
    private var listenFd: Int32 = -1
    private var running = false
    private let methods: RPCMethods
    private var connections: [Int32: ClientConn] = [:]
    private let heartbeatSec: Int
    private let deadSec: Int
    private var heartbeatTask: Task<Void, Never>?
    private let bus: EventBus
    private let maxLineBytes: Int = 1_048_576
    private let nodeId: String

    init(sockPath: String, methods: RPCMethods, bus: EventBus, heartbeatSec: Int, deadSec: Int, nodeId: String) {
        self.sockPath = sockPath
        self.methods = methods
        self.bus = bus
        self.heartbeatSec = heartbeatSec
        self.deadSec = deadSec
        self.allowedUid = getuid()
        self.nodeId = nodeId
    }

    func start() async {
        let path = self.sockPath
        unlink(path)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            FusionLog.ipc.error("ipc socket create fail")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
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
        guard bound else {
            FusionLog.ipc.error("ipc bind fail \(String(cString: strerror(errno)))")
            Darwin.close(listenFd); listenFd = -1
            return
        }
        Darwin.listen(listenFd, 16)
        chmod(path, 0o600)
        running = true
        FusionLog.ipc.info("ipc listen \(path, privacy: .public) mode=0600 allowed_uid=\(self.allowedUid)")
        startHeartbeat()
        let lfd = listenFd
        Task { [weak self] in await self?.acceptLoop(listenFd: lfd) }
    }

    func stop() async {
        running = false
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if listenFd >= 0 {
            Darwin.close(listenFd); listenFd = -1
        }
        for (fd, conn) in connections {
            conn.cont?.finish()
            conn.markClosed()
            Darwin.close(fd)
        }
        connections.removeAll()
        unlink(self.sockPath)
        FusionLog.ipc.info("ipc stopped")
    }

    private nonisolated func acceptLoop(listenFd: Int32) async {
        while await isRunning() {
            var clientAddr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = Darwin.accept(listenFd, &clientAddr, &len)
            if cfd < 0 {
                let alive = await isRunning()
                if alive { FusionLog.ipc.error("ipc accept fail") }
                if !alive { break }
                continue
            }
            let ok = await checkPeer(fd: cfd)
            if !ok {
                FusionLog.ipc.error("ipc reject peer uid mismatch fd=\(cfd)")
                Darwin.close(cfd)
                continue
            }
            await registerConn(fd: cfd)
            Task { [weak self] in await self?.handleClient(fd: cfd) }
        }
    }

    private func checkPeer(fd: Int32) -> Bool {
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        let rc = Darwin.getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen)
        guard rc == 0 else {
            FusionLog.ipc.error("ipc getsockopt LOCAL_PEERCRED fail fd=\(fd) errno=\(errno)")
            return false
        }
        if cred.cr_uid != allowedUid {
            FusionLog.ipc.error("ipc peer uid=\(cred.cr_uid) != allowed=\(self.allowedUid), reject (F1)")
            return false
        }
        return true
    }

    private func isRunning() -> Bool { running }

    private func registerConn(fd: Int32) {
        var nosig: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        connections[fd] = ClientConn(fd: fd)
    }

    private nonisolated func handleClient(fd: Int32) async {
        let (stream, cont, subId) = await bus.subscribe()
        await setConnCont(fd: fd, cont: cont)
        Task { [weak self] in await self?.pumpEvents(fd: fd, stream: stream) }
        var buf = Data()
        buf.reserveCapacity(8192)
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        defer { chunk.deallocate() }
        let cap = await maxLine()
        while await isRunning() {
            let n = Darwin.recv(fd, chunk, 8192, 0)
            if n <= 0 { break }
            let got = UnsafeBufferPointer(start: chunk, count: n)
            var lineStart = 0
            for i in 0..<n {
                if got[i] == 0x0A {
                    let lineLen = buf.count + (i - lineStart)
                    if lineLen <= cap {
                        buf.append(UnsafeBufferPointer(start: chunk.advanced(by: lineStart), count: i - lineStart))
                        await processLine(fd: fd, data: buf)
                        buf.removeAll(keepingCapacity: true)
                    } else {
                        FusionLog.ipc.error("ipc line oversize \(lineLen) > cap, drop fd=\(fd)")
                        buf.removeAll(keepingCapacity: true)
                    }
                    lineStart = i + 1
                }
            }
            if lineStart < n {
                buf.append(UnsafeBufferPointer(start: chunk.advanced(by: lineStart), count: n - lineStart))
                if buf.count > cap {
                    FusionLog.ipc.error("ipc partial line oversize, drop fd=\(fd)")
                    buf.removeAll(keepingCapacity: true)
                }
            }
        }
        cont.finish()
        await bus.removeSubscriber(subId)
        await closeConn(fd: fd)
        FusionLog.ipc.info("ipc client disconnect fd=\(fd)")
    }

    private func maxLine() -> Int { maxLineBytes }

    private func setConnCont(fd: Int32, cont: AsyncStream<RawEvent>.Continuation) {
        if var conn = connections[fd] {
            conn.cont = cont
            conn.lastSeen = UInt64(Date().timeIntervalSince1970)
            connections[fd] = conn
        }
    }

    private func closeConn(fd: Int32) {
        guard let conn = connections[fd] else { return }
        conn.markClosed()
        connections.removeValue(forKey: fd)
        Darwin.close(fd)
    }

    private nonisolated func pumpEvents(fd: Int32, stream: AsyncStream<RawEvent>) async {
        let fdLocal = fd
        for await event in stream {
            let closed = await isConnClosed(fd: fdLocal)
            guard closed == false else { break }
            let note = RPCNotification(
                method: "event.notification",
                params: AnyCodable(
                    [
                        "event": eventDict(event),
                        "source": event.sourceType.rawValue
                    ] as [String: Any]))
            let data = RPCCodec.line(RPCCodec.encode(note))
            let ok = await Self.writeAll(fd: fd, data: data)
            if !ok { break }
        }
    }

    private func getConn(fd: Int32) -> ClientConn? { connections[fd] }

    private func isConnClosed(fd: Int32) -> Bool {
        connections[fd]?.isClosed() ?? true
    }

    private nonisolated func processLine(fd: Int32, data: Data) async {
        await touchConn(fd: fd)
        guard !data.isEmpty else { return }
        switch RPCCodec.decodeBatch(data) {
        case .malformed:
            let errResp = RPCResponse(id: nil, result: nil, error: RPCError(code: RPCErrorCode.parseError.rawValue, message: "parse error"))
            await Self.writeAll(fd: fd, data: RPCCodec.line(RPCCodec.encode(errResp)))
        case .single(let req):
            if req.method == "event.pong" {
                await touchConn(fd: fd)
                return
            }
            let resp = await methods.dispatch(req: req)
            if req.id == nil {
                return
            }
            await Self.writeAll(fd: fd, data: RPCCodec.line(RPCCodec.encode(resp)))
        case .batch(let reqs):
            var responses: [RPCResponse] = []
            for req in reqs {
                if req.method == "event.pong" {
                    await touchConn(fd: fd)
                    continue
                }
                let resp = await methods.dispatch(req: req)
                if req.id != nil {
                    responses.append(resp)
                }
            }
            guard !responses.isEmpty else { return }
            await Self.writeAll(fd: fd, data: RPCCodec.line(RPCCodec.encode(responses)))
        }
    }

    private func touchConn(fd: Int32) {
        if var conn = connections[fd] {
            conn.lastSeen = UInt64(Date().timeIntervalSince1970)
            connections[fd] = conn
        }
    }

    private nonisolated static func writeAll(fd: Int32, data: Data) async -> Bool {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { buf -> Int in
                guard let base = buf.baseAddress?.advanced(by: sent) else { return -1 }
                return Darwin.send(fd, base, data.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    private nonisolated func eventDict(_ e: RawEvent) -> [String: Any] {
        [
            "eventId": UUID().uuidString,
            "type": e.sourceType.rawValue,
            "targetPath": e.targetPath ?? "",
            "timestamp": e.timestamp,
            "payload": e.payload,
            "nodeId": nodeId
        ]
    }

    private func startHeartbeat() {
        let interval = self.heartbeatSec
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                await self?.heartbeatSweep()
            }
        }
    }

    private func heartbeatSweep() async {
        let now = UInt64(Date().timeIntervalSince1970)
        let note = RPCNotification(method: "event.heartbeat", params: AnyCodable(["ts": now]))
        let data = RPCCodec.line(RPCCodec.encode(note))
        let snapshot = connections
        let deadSecLocal = UInt64(deadSec)
        let writeResults = await withTaskGroup(of: (Int32, Bool).self) { group in
            for (fd, _) in snapshot {
                group.addTask { await (fd, Self.writeAll(fd: fd, data: data)) }
            }
            var res: [(Int32, Bool)] = []
            for await r in group { res.append(r) }
            return res
        }
        var dead: [Int32] = []
        let writeOk: [Int32: Bool] = Dictionary(uniqueKeysWithValues: writeResults)
        for (fd, conn) in snapshot {
            let ok = writeOk[fd] ?? false
            if !ok || now - conn.lastSeen > deadSecLocal {
                dead.append(fd)
            }
        }
        for fd in dead {
            FusionLog.ipc.notice("ipc dead/closed connection fd=\(fd), cleanup (E6, F-15: non-blocking heartbeat sweep)")
            if let conn = connections[fd] {
                conn.cont?.finish()
                conn.markClosed()
                connections.removeValue(forKey: fd)
                Darwin.close(fd)
            }
        }
    }

    final class ClientConn {
        let fd: Int32
        var cont: AsyncStream<RawEvent>.Continuation?
        var lastSeen: UInt64 = 0
        private var closed: Bool = false

        init(fd: Int32) {
            self.fd = fd
        }

        func markClosed() { closed = true }
        func isClosed() -> Bool { closed }
    }
}
