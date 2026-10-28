import Foundation
import MediaPlayer

/// Makes the keyboard's play/pause/skip keys (and headphone buttons) drive Spotify,
/// and shows the current track in macOS's Now Playing.
final class MediaKeys {
    private weak var player: PlayerWindowController?

    init(player: PlayerWindowController) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player?.control("toggle")
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.player?.control("play")
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.control("pause")
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.player?.control("next")
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.player?.control("prev")
            return .success
        }
    }

    func update(_ info: NowPlaying) {
        let center = MPNowPlayingInfoCenter.default()
        if info.title.isEmpty {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist
        ]
        center.playbackState = info.playing ? .playing : .paused
    }
}
