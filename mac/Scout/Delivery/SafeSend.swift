import Foundation

enum SafeSendVariant: String, CaseIterable {
    case off
    case select
    case undo
    case unusual

    static var current: SafeSendVariant {
        let prefix = "--safe-send="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }), let value = SafeSendVariant(rawValue: String(argument.dropFirst(prefix.count))) {
            return value
        }
        return UserDefaults.standard.string(forKey: "ScoutSafeSend").flatMap(SafeSendVariant.init(rawValue:)) ?? .off
    }

    static var undoSeconds: Double {
        let value = UserDefaults.standard.double(forKey: "ScoutSafeSendUndoSeconds")
        return value > 0 ? value : 4
    }

    static var mockSuggestion: String? {
        if let value = UserDefaults.standard.string(forKey: "ScoutMockSuggestion") { return value.isEmpty ? nil : value.lowercased() }
        return current == .off ? nil : "scout"
    }
}

struct PendingSend: Equatable {
    var target: ApiaryTarget
    var mode: DeliveryMode
    var started: Date
    var seconds: Double
}
