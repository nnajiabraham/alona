import AVFoundation
import Foundation

final class RecordingAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var playingURL: URL?
    @Published private(set) var lastError: String?

    private var player: AVAudioPlayer?

    func play(url: URL) {
        DispatchQueue.main.async {
            self.lastError = nil
        }
        do {
            stop()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            DispatchQueue.main.async {
                self.isPlaying = true
                self.playingURL = url
            }
        } catch {
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                self.isPlaying = false
                self.playingURL = nil
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        DispatchQueue.main.async {
            self.isPlaying = false
            self.playingURL = nil
        }
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.playingURL = nil
            self.player = nil
        }
    }
}
