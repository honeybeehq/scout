import AppKit

struct RecordRequest: Equatable {
    var target: ApiaryTarget

    static func parse(_ url: URL) -> RecordRequest? {
        guard url.scheme?.lowercased() == "scout", url.host?.lowercased() == "record",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "target" })?.value,
              value.hasPrefix("proof:")
        else { return nil }
        let id = String(value.dropFirst("proof:".count))
        guard (1...128).contains(id.count),
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { return nil }
        return RecordRequest(target: ApiaryTarget(kind: "proof", id: id, sessionID: nil, title: "the proof"))
    }
}

final class ScoutAppDelegate: NSObject, NSApplicationDelegate {
    static var onRecord: ((RecordRequest) -> Void)? {
        didSet {
            guard let onRecord else { return }
            let waiting = pending
            pending = []
            waiting.forEach(onRecord)
        }
    }

    private static var pending: [RecordRequest] = []

    static var onWillFinishLaunching: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.onWillFinishLaunching?()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = RecordRequest.parse(url) else {
                NSSound.beep()
                continue
            }
            if let handler = Self.onRecord { handler(request) } else { Self.pending.append(request) }
        }
    }
}
