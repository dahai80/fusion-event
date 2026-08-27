import Foundation
import os

enum LogCategory: String {
    case lifecycle
    case source
    case rule
    case ipc
    case bridge
    case persist
    case metrics
}

enum FusionLog {
    static let subsystem = "com.fusion.event"

    static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    static let lifecycle = Logger(subsystem: subsystem, category: LogCategory.lifecycle.rawValue)
    static let source = Logger(subsystem: subsystem, category: LogCategory.source.rawValue)
    static let rule = Logger(subsystem: subsystem, category: LogCategory.rule.rawValue)
    static let ipc = Logger(subsystem: subsystem, category: LogCategory.ipc.rawValue)
    static let bridge = Logger(subsystem: subsystem, category: LogCategory.bridge.rawValue)
    static let persist = Logger(subsystem: subsystem, category: LogCategory.persist.rawValue)
    static let metrics = Logger(subsystem: subsystem, category: LogCategory.metrics.rawValue)
}
