import Foundation
import Combine
import AVFoundation

@MainActor
final class KaraokePlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var activeWordID: UUID?
    private var player: AVAudioPlayer?
    private var timings: [WordTiming] = []
    private var ticker: Timer?

    func load(url: URL, timings: [WordTiming]) throws {
        stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        self.timings = timings.sorted { $0.start < $1.start }
        player?.prepareToPlay()
    }

    func play() {
        guard let player else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.play()
        isPlaying = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
    }

    func stop() {
        player?.stop()
        ticker?.invalidate()
        isPlaying = false
        currentTime = 0
        activeWordID = nil
    }

    private func refresh() {
        guard let player else { return }
        currentTime = player.currentTime
        activeWordID = timings.first(where: { currentTime >= $0.start && currentTime < $0.end })?.id
        if !player.isPlaying {
            isPlaying = false
            ticker?.invalidate()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        ticker?.invalidate()
        activeWordID = nil
    }
}
