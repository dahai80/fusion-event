import Foundation

public struct ESSnapshotXPC: Codable, Sendable, Equatable {
    public let pid: Int32
    public let execPath: String?
    public let action: String
    public let timestamp: UInt64
    public let source: String

    public init(pid: Int32, execPath: String?, action: String, timestamp: UInt64, source: String = "endpoint-security") {
        self.pid = pid
        self.execPath = execPath
        self.action = action
        self.timestamp = timestamp
        self.source = source
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> ESSnapshotXPC {
        try JSONDecoder().decode(ESSnapshotXPC.self, from: data)
    }
}

@objc public protocol ESXPCProtocol {
    func deliverEvent(_ payload: NSData)
}
