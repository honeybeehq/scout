import SwiftUI

struct VoiceSection: View {
    @Environment(AppModel.self) private var model
    @State private var locales: [String] = []
    @State private var automaticTitle = "Automatic"

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsSection(title: "Recognition") {
            SettingRow(title: "Apple recognizer", detail: nil, divider: false) {
                SegmentedChoice(options: TranscriptionModule.allCases, selection: $preferences.transcriptionModule, title: \.title)
            }
            SettingNote(text: preferences.transcriptionModule.explanation)
            SettingRow(title: "Transcription language", detail: "Automatic follows this Mac's language list.") {
                ChoiceMenu(options: [TranscriptionLocale.automatic] + locales, selection: $preferences.transcriptionLocale) { option in
                    option == TranscriptionLocale.automatic ? automaticTitle : TranscriptionLocale.title(for: option)
                }
            }
            SettingRow(title: "Words Scout should know", detail: "Names, products and jargon, one per line or separated by commas. Scout also learns app names, window titles and labels while you scout. Only Dictation uses them.") {
                EmptyView()
            }
            TextField("Apiary, Honeybee, portless…", text: $preferences.transcriptionTerms, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(Typography.mono)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.sunken, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
                .padding(.bottom, 12)
        }
        .task {
            locales = await TranscriptionLocale.options()
            if let choice = await TranscriptionLocale.resolve(preference: TranscriptionLocale.automatic) {
                automaticTitle = "Automatic (\(TranscriptionLocale.title(for: choice.identifier)))"
            }
        }
    }
}
