import AVFoundation
import AVKit
import Observation
import ScoutCore
import SwiftUI

@Observable
final class ReviewPlayer {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var loadedURL: URL?
    var loopsTask = true

    private weak var review: SessionReview?
    private var timeObserver: Any?

    func attach(_ review: SessionReview) {
        self.review = review
        guard let url = review.video?.url else {
            player.replaceCurrentItem(with: nil)
            loadedURL = nil
            return
        }
        guard loadedURL != url else { return }
        loadedURL = url
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.actionAtItemEnd = .pause
        installObserver()
        seek(to: review.playhead)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let review, let task = review.selectedTask else {
            player.play()
            isPlaying = true
            return
        }
        let range = task.snippet.range
        if review.playhead < range.start || review.playhead >= range.end - 0.05 {
            seek(to: range.start)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: SessionTime) {
        guard let review else { return }
        review.playhead = time
        let target = CMTime(seconds: review.videoTime(forSessionTime: time), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func detach() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func installObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func tick(_ time: CMTime) {
        guard let review, isPlaying else { return }
        let sessionTime = review.sessionTime(forVideoTime: time.seconds)
        review.playhead = sessionTime
        if player.rate == 0 { isPlaying = false }
        guard let range = review.selectedTask?.snippet.range, sessionTime >= range.end else { return }
        if loopsTask {
            seek(to: range.start)
        } else {
            pause()
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
