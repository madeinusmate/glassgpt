import Foundation

enum LogCategory: String, Equatable {
    case app
    case sdk
    case device
    case stream
    case session
    case permission
    case navigation
    case audio
    case realtime
    case vision
    case location

    var label: String {
        rawValue.uppercased()
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: String
    let category: LogCategory
    let message: String

    var formatted: String {
        "[\(timestamp)] [\(category.label)] \(message)"
    }
}
