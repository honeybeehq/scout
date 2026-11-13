import Foundation
import Speech

nonisolated enum TranscriptionLocale {
    static let automatic = "automatic"

    struct Choice: Sendable {
        var locale: Locale
        var requested: String
        var fellBack: Bool

        var identifier: String { locale.identifier(.bcp47) }
    }

    static func resolve(preference: String, module: TranscriptionModule = .speech) async -> Choice? {
        let supported: [Locale]
        switch module {
        case .speech: supported = await SpeechTranscriber.supportedLocales
        case .dictation: supported = await DictationTranscriber.supportedLocales
        }
        func match(_ identifier: String) async -> Locale? {
            let equivalent: Locale?
            switch module {
            case .speech: equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
            case .dictation: equivalent = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
            }
            guard let locale = equivalent else { return nil }
            return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) } ? locale : nil
        }
        let requested = preference.trimmingCharacters(in: .whitespaces)
        if !requested.isEmpty, requested != automatic, let locale = await match(requested) {
            return Choice(locale: locale, requested: requested, fellBack: false)
        }
        let wanted = requested.isEmpty ? automatic : requested
        for candidate in Locale.preferredLanguages + [Locale.current.identifier, "en-US"] {
            if let locale = await match(candidate) {
                return Choice(locale: locale, requested: wanted, fellBack: wanted != automatic)
            }
        }
        return nil
    }

    static func options() async -> [String] {
        await SpeechTranscriber.supportedLocales
            .map { $0.identifier(.bcp47) }
            .sorted { title(for: $0).localizedStandardCompare(title(for: $1)) == .orderedAscending }
    }

    static func title(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
