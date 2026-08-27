import Foundation

actor IPCServer {
    private let sockPath: String
    private var listenFd: Int32 = -1
    private var running = false
    private let methods: RPCMethods
    private var connections: [Int32: ClientConn] = [:]
    private let heartbeatSec: Int
    private let deadSec: Int
    private var heartbeatTask: Task<Void, Never>?
    private let bus: EventBus

    init(sockPath: String, methods: RPCMethods, bus: EventBus, heartbeatSec: Int, deadSec: Int) {
        self.sockPath = sockPath
        self.methods = methods
        self.bus = bus
        self.heartbeatSec = heartbeatSec
        self.deadSec = deadSec
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
        chmod(path, 0o666)
        running = true
        FusionLog.ipc.info("ipc listen \(path, privacy: .public)")
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
            await registerConn(fd: cfd)
            Task { [weak self] in await self?.handleClient(fd: cfd) }
        }
    }

    private func isRunning() -> Bool { running }

    private func registerConn(fd: Int32) {
        connections[fd] = ClientConn(fd: fd)
    }

    private nonisolated func handleClient(fd: Int32) async {
        let (stream, cont, subId) = await bus.subscribe()
        await setConnCont(fd: fd, cont: cont)
        Task { [weak self] in await self?.pumpEvents(fd: fd, stream: stream) }
        var buf = Data()
        var byte: [UInt8] = [0]
        while await isRunning() {
            let n = Darwin.recv(fd, &byte, 1, 0)
            if n <= 0 { break }
            if byte[0] == 0x0A {
                await processLine(fd: fd, data: buf)
                buf.removeAll()
            } else {
                buf.append(byte[0])
            }
        }
        cont.finish()
        await bus.removeSubscriber(subId)
        Darwin.close(fd)
        await removeConn(fd: fd)
        FusionLog.ipc.info("ipc client disconnect fd=\(fd)")
    }

    private func setConnCont(fd: Int32, cont: AsyncStream<RawEvent>.Continuation) {
        if var conn = connections[fd] {
            conn.cont = cont
            conn.lastSeen = UInt64(Date().timeIntervalSince1970)
            connections[fd] = conn
        }
    }

    private func removeConn(fd: Int32) {
        connections.removeValue(forKey: fd)
    }

    private nonisolated func pumpEvents(fd: Int32, stream: AsyncStream<RawEvent>) async {
        for await event in stream {
            let note = RPCNotification(method: "event.notification", params: AnyCodable([
                "event": Self.eventDict(event),
                "source": event.sourceType.rawValue
            ] as [String: Any]))
            let data = RPCCodec.line(RPCCodec.encode(note))
            _ = data.withUnsafeBytes { buf -> Int in
                Darwin.send(fd, buf.baseAddress, data.count, 0)
            }
        }
    }

    private nonisolated func processLine(fd: Int32, data: Data) async {
        await touchConn(fd: fd)
        guard !data.isEmpty else { return }
        guard let req = RPCCodec.decodeRequest(data) else {
            let err = RPCResponse(id: nil, result: nil, error: RPCError(code: RPCErrorCode.parseError.rawValue, message: "parse error"))
            Self.send(fd: fd, resp: err)
            return
        }
        if req.method == "event.pong" {
            return
        }
        let resp = await methods.dispatch(req: req)
        Self.send(fd: fd, resp: resp)
    }

    private func touchConn(fd: Int32) {
        if var conn = connections[fd] {
            conn.lastSeen = UInt64(Date().timeIntervalSince1970)
            connections[fd] = conn
        }
    }

    private nonisolated static func send(fd: Int32, resp: RPCResponse) {
        let data = RPCCodec.line(RPCCodec.encode(resp))
        _ = data.withUnsafeBytes { buf -> Int in
            Darwin.send(fd, buf.baseAddress, data.count, 0)
        }
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
        for (fd, conn) in connections {
            _ = data.withUnsafeBytes { buf -> Int in
                Darwin.send(fd, buf.baseAddress, data.count, 0)
            }
            if now - conn.lastSeen > UInt64(deadSec) {
                FusionLog.ipc.notice("ipc dead connection fd=\(fd), cleanup (E6)")
                conn.cont?.finish()
                Darwin.close(fd)
                connections.removeValue(forKey: fd)
            }
        }
    }

    private nonisolated static func eventDict(_ e: RawEvent) -> [String: Any] {
        [
            "eventId": UUID().uuidString,
            "type": e.sourceType.rawValue,
            "targetPath": e.targetPath ?? "",
            "timestamp": e.timestamp,
            "payload": e.payload,
            "nodeId": ""
        ]
    }

    struct ClientConn {
        let fd: Int32
        var cont: AsyncStream<RawEvent>.Continuation?
        var lastSeen: UInt64 = 0
    }
}
