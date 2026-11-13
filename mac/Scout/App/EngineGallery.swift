import AppKit
import SwiftUI

enum EngineGallery {
    static var directory: URL? {
        let prefix = "--engine-gallery="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    private static let megabyte: Int64 = 1_000_000
    private static let installed = 649 * megabyte

    private static var onboarding: [(String, TranscriptionEngineChoice, WhisperModelSnapshot)] {
        [
            ("1-offer", .apple, .init(state: .notInstalled)),
            ("2-downloading", .whisper, .init(state: .downloading(progress: 0.42))),
            ("3-verifying", .whisper, .init(state: .verifying(progress: 0.7))),
            ("4-preparing", .whisper, .init(state: .preparing, installedBytes: installed, preparingSince: .now.addingTimeInterval(-42))),
            ("5-ready", .whisper, .init(state: .ready, installedBytes: installed)),
            ("6-paused", .whisper, .init(state: .notInstalled, partialBytes: 211 * megabyte)),
            ("7-failed", .whisper, .init(state: .failed("The network connection was lost."), partialBytes: 120 * megabyte)),
            ("8-apple-with-model", .apple, .init(state: .ready, installedBytes: installed)),
        ]
    }

    private static var settings: [(String, TranscriptionEngineChoice, WhisperModelSnapshot, Bool)] {
        [
            ("1-apple", .apple, .init(state: .notInstalled), false),
            ("2-whisper-missing", .whisper, .init(state: .notInstalled), false),
            ("3-downloading", .whisper, .init(state: .downloading(progress: 0.42)), false),
            ("4-paused", .whisper, .init(state: .notInstalled, partialBytes: 211 * megabyte), false),
            ("5-verifying", .whisper, .init(state: .verifying(progress: 0.7)), false),
            ("6-preparing", .whisper, .init(state: .preparing, installedBytes: installed, preparingSince: .now.addingTimeInterval(-42)), false),
            ("7-ready", .whisper, .init(state: .ready, installedBytes: installed), false),
            ("8-remove-confirm", .whisper, .init(state: .ready, installedBytes: installed), true),
            ("9-failed", .whisper, .init(state: .failed("SHA-256 mismatch for AudioEncoder.mlmodelc/weights/weight.bin. The file was removed; try again to download it."), partialBytes: 226 * megabyte), false),
        ]
    }

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(300))
        for scheme in DesignGallery.schemes {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(80))
            for size in [UISize.standard, .extraLarge] {
                let suffix = "\(scheme == .dark ? "dark" : "light")-\(size.rawValue)"
                for (name, engine, whisper) in onboarding {
                    let view = OnboardingFrame(engine: engine, whisper: whisper).environment(model).scaled(by: size.scale)
                    render(view, scheme: scheme, to: directory.appendingPathComponent("onboarding-\(name)-\(suffix).png"))
                }
                for (name, engine, whisper, confirming) in settings {
                    let view = SettingsFrame(engine: engine, whisper: whisper, confirmingRemove: confirming).scaled(by: size.scale)
                    render(view, scheme: scheme, to: directory.appendingPathComponent("settings-\(name)-\(suffix).png"))
                }
            }
        }
        NSApp.terminate(nil)
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.stillRender, true).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private struct OnboardingFrame: View {
        var engine: TranscriptionEngineChoice
        var whisper: WhisperModelSnapshot

        var body: some View {
            ZStack {
                SignalBackdrop(intensity: OnboardingModel.Step.transcriber.glowIntensity)
                VStack(spacing: 0) {
                    StepRail(current: .transcriber)
                        .padding(.top, 22)
                    TranscriberStepContent(engine: engine, whisper: whisper, useApple: {}, useWhisper: {}, actions: WhisperModelActions(), onContinue: {})
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: OnboardingView.size.width, height: OnboardingView.size.height)
        }
    }

    private struct SettingsFrame: View {
        var engine: TranscriptionEngineChoice
        var whisper: WhisperModelSnapshot
        var confirmingRemove: Bool

        var body: some View {
            TranscriberSettingsContent(engine: .constant(engine), whisper: whisper, actions: WhisperModelActions(), confirmingRemove: confirmingRemove)
                .padding(20)
                .frame(width: SettingsView.size.width, alignment: .top)
                .background(Palette.canvas)
        }
    }
}
