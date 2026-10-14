import CryptoKit
import Foundation
import ScoutCore

nonisolated enum ScoutUUID {
    static let namespace = UUID(uuidString: "e0aaba76-1ff7-5558-a034-b585db29a50a")!

    static func v5(_ name: String, namespace: UUID = ScoutUUID.namespace) -> String {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }
}

enum DeliveryMode: String, Sendable {
    case paste
    case send
}

struct DeliveryOutcome: Sendable {
    enum Route: String, Sendable {
        case apiary
        case hive
        case clipboard
    }

    var route: Route
    var mode: DeliveryMode
    var title: String
    var deliveryID: String
    var messageID: String
    var deduped: Bool
    var fallbackReason: String?
    var roundTripMs: Double

    var confirmation: String {
        switch route {
        case .apiary: mode == .paste ? "Pasted into \(title)" : "Sent to \(title)"
        case .hive: deduped ? "Already sent to \(title)" : "Sent to \(title)"
        case .clipboard: "On the clipboard. Apiary isn't showing a chat"
        }
    }
}

struct WalkthroughDelivery {
    struct Failure: LocalizedError {
        var code: String
        var message: String
        var errorDescription: String? { message }
    }

    let apiary: ApiaryBridge
    let hive: HiveClient

    static func deliveryID(walkthrough: String, target: ApiaryTarget, mode: DeliveryMode) -> String {
        "scout:\(walkthrough):\(target.kind):\(target.id):\(mode.rawValue)"
    }

    func deliver(bundle directory: URL, walkthrough: String, to target: ApiaryTarget, mode: DeliveryMode, viaApiary: Bool) async throws -> DeliveryOutcome {
        let deliveryID = Self.deliveryID(walkthrough: walkthrough, target: target, mode: mode)
        let messageID = ScoutUUID.v5(deliveryID)
        let started = ContinuousClock.now
        func outcome(_ route: DeliveryOutcome.Route, title: String, deduped: Bool = false, reason: String? = nil) -> DeliveryOutcome {
            DeliveryOutcome(route: route, mode: mode, title: title, deliveryID: deliveryID, messageID: messageID, deduped: deduped, fallbackReason: reason, roundTripMs: ApiaryBridge.milliseconds(ContinuousClock.now - started))
        }
        var reason = "apiary absent"
        if !viaApiary, mode == .paste {
            return outcome(.clipboard, title: target.title, reason: reason)
        }
        if viaApiary {
            let params: JSONValue = .object([
                "deliveryId": .string(deliveryID),
                "bundlePath": .string(directory.path),
                "target": target.reference,
                "mode": .string(mode.rawValue),
                "urgency": .string("next"),
            ])
            do {
                let answer = try await apiary.deliver(params)
                var title = target.title
                if case .object(let resolved)? = answer["target"], case .string(let name)? = resolved["title"], !name.isEmpty { title = name }
                if case .string(let returned)? = answer["messageId"], returned != messageID {
                    throw Failure(code: "messageIdMismatch", message: "Apiary derived \(returned), Scout derived \(messageID).")
                }
                return outcome(.apiary, title: title)
            } catch let error as ApiaryBridgeError {
                switch error.code {
                case "noRenderer", "notReady", "timeout", "unreachable", "absent":
                    reason = error.code
                default:
                    throw Failure(code: error.code, message: error.localizedDescription)
                }
            }
            if mode == .paste {
                return outcome(.clipboard, title: target.title, reason: reason)
            }
        }
        guard let session = target.sessionID else {
            throw Failure(code: "noSession", message: "\(target.title) has no session to send to.")
        }
        let text = try String(contentsOf: directory.appendingPathComponent(WalkthroughBundle.textName), encoding: .utf8)
        let body = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let receipt = try await hive.send(to: session, body: body, idempotencyKey: messageID)
        return outcome(.hive, title: target.title, deduped: receipt.deduped, reason: reason)
    }
}
