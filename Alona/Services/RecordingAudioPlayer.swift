import AVFoundation
import Foundation

@MainActor
final class RecordingAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var playingURL: URL?
    @Published private(set) var lastError: String?

    private var player: AVAudioPlayer?

    func play(url: URL) {
        self.lastError = nil
        do {
            self.stop()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            self.isPlaying = true
            self.playingURL = url
        } catch {
            self.lastError = error.localizedDescription
            self.isPlaying = false
            self.playingURL = nil
        }
    }

    func stop() {
        self.player?.stop()
        self.player = nil
        self.isPlaying = false
        self.playingURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.playingURL = nil
            self.player = nil
        }
    }
}
