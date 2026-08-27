import Foundation

public enum SystemEventType: String, Codable, Sendable {
    case fileModified
    case processTerminated
    case clipboardChanged
    case networkStatusChanged
    case systemWake
    case systemSleep
}

public struct SystemEvent: Codable, Sendable, Equatable {
    public let eventId: String
    public let type: SystemEventType
    public let targetPath: String?
    public let timestamp: UInt64
    public let payload: [String: String]
    public let nodeId: String

    public init(
        eventId: String,
        type: SystemEventType,
        targetPath: String?,
        timestamp: UInt64,
        payload: [String: String],
        nodeId: String
    ) {
        self.eventId = eventId
        self.type = type
        self.targetPath = targetPath
        self.timestamp = timestamp
        self.payload = payload
        self.nodeId = nodeId
    }
}

public struct RawEvent: Sendable {
    public let sourceType: SystemEventType
    public let targetPath: String?
    public let timestamp: UInt64
    public let payload: [String: String]
    public let rawFlags: UInt32

    public init(
        sourceType: SystemEventType,
        targetPath: String?,
        timestamp: UInt64,
        payload: [String: String],
        rawFlags: UInt32
    ) {
        self.sourceType = sourceType
        self.targetPath = targetPath
        self.timestamp = timestamp
        self.payload = payload
        self.rawFlags = rawFlags
    }
}

public struct EventRule: Codable, Sendable, Equatable {
    public let ruleName: String
    public let eventType: SystemEventType
    public let pathPattern: String?
    public let debounceMs: Int
    public let throttleMs: Int
    public let throttleMaxPerWindow: Int
    public let targetAgent: String
    public let targetGraphId: String?
    public let enabled: Bool
    public let maxRetries: Int
    public let requireGuard: Bool

    public init(
        ruleName: String,
        eventType: SystemEventType,
        pathPattern: String?,
        debounceMs: Int,
        throttleMs: Int,
        throttleMaxPerWindow: Int = 1,
        targetAgent: String,
        targetGraphId: String?,
        enabled: Bool,
        maxRetries: Int,
        requireGuard: Bool
    ) {
        self.ruleName = ruleName
        self.eventType = eventType
        self.pathPattern = pathPattern
        self.debounceMs = debounceMs
        self.throttleMs = throttleMs
        self.throttleMaxPerWindow = max(throttleMaxPerWindow, 1)
        self.targetAgent = targetAgent
        self.targetGraphId = targetGraphId
        self.enabled = enabled
        self.maxRetries = maxRetries
        self.requireGuard = requireGuard
    }
}

public struct TriggerSignal: Sendable, Codable {
    public let event: SystemEvent
    public let rule: EventRule
    public let triggerId: String
    public let idempotencyKey: String
    public let nodeId: String

    public init(
        event: SystemEvent,
        rule: EventRule,
        triggerId: String,
        idempotencyKey: String,
        nodeId: String
    ) {
        self.event = event
        self.rule = rule
        self.triggerId = triggerId
        self.idempotencyKey = idempotencyKey
        self.nodeId = nodeId
    }
}

public enum GuardDecision: String, Codable, Sendable {
    case pass
    case block
    case challenge
}

public struct GuardAuditResult: Codable, Sendable {
    public let decision: GuardDecision
    public let reason: String
    public let riskLevel: Int
    public let auditId: String

    public init(decision: GuardDecision, reason: String, riskLevel: Int, auditId: String) {
        self.decision = decision
        self.reason = reason
        self.riskLevel = riskLevel
        self.auditId = auditId
    }
}

public struct ContextResult: Codable, Sendable {
    public let context: String
    public let memoryIds: [String]
    public let cacheHit: Bool
    public let contextStale: Bool

    public init(context: String, memoryIds: [String], cacheHit: Bool, contextStale: Bool) {
        self.context = context
        self.memoryIds = memoryIds
        self.cacheHit = cacheHit
        self.contextStale = contextStale
    }
}
