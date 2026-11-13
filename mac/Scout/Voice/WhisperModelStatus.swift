import SwiftUI

struct WhisperModelSnapshot: Equatable {
    var state: WhisperModelStore.State
    var installedBytes: Int64 = 0
    var partialBytes: Int64 = 0
    var preparingSince: Date?
    var downloadBytes: Int64 = WhisperModelStore.downloadBytes

    var isPaused: Bool {
        state == .notInstalled && partialBytes > 0
    }

    var isInstalled: Bool {
        state == .ready || state == .preparing
    }

    var progress: Double? {
        switch state {
        case .downloading(let progress), .verifying(let progress): min(1, max(0, progress))
        case .notInstalled, .preparing, .ready, .failed: nil
        }
    }

    var downloadSize: String {
        "About \(Self.roundedMegabytes(downloadBytes)) MB"
    }

    var pausedLine: String {
        "Paused at \(Self.megabytes(partialBytes)) of \(Self.megabytes(downloadBytes)) MB · \(Self.megabytes(max(0, downloadBytes - partialBytes))) MB to go"
    }

    var downloadingLine: String {
        let done = Int64((progress ?? 0) * Double(downloadBytes))
        return "Downloading · \(Self.megabytes(done)) of \(Self.megabytes(downloadBytes)) MB"
    }

    var verifyingLine: String {
        "Checking the download · \(Int((progress ?? 0) * 100))%"
    }

    var installedLine: String {
        "Installed · \(Self.megabytes(installedBytes)) MB on disk"
    }

    static func megabytes(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 1_000_000).rounded())
    }

    static func roundedMegabytes(_ bytes: Int64) -> Int {
        Int((Double(bytes) / 50_000_000).rounded()) * 50
    }
}

extension WhisperModelStore {
    var snapshot: WhisperModelSnapshot {
        WhisperModelSnapshot(state: state, installedBytes: installedBytes, partialBytes: partialBytes, preparingSince: preparingSince)
    }
}

extension WhisperModelStore.State {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

struct WhisperModelActions {
    var download: () -> Void = {}
    var cancel: () -> Void = {}
    var remove: () -> Void = {}
}

struct DownloadMeter: View {
    var progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Palette.fillStrong)
                Rectangle()
                    .fill(Palette.text)
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 3)
        .clipShape(.rect(cornerRadius: 1.5))
        .animation(Motion.smooth, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct PreparingLine: View {
    var since: Date?

    var body: some View {
        HStack(spacing: 8) {
            WaitingDots()
            Text("Preparing model…")
                .font(Typography.headline)
                .foregroundStyle(Palette.text)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .font(Typography.numeric)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static let expectation = "About 2 minutes the first time."
}
