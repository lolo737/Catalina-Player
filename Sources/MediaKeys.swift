import Foundation
import MediaPlayer

/// Makes the keyboard's play/pause/skip keys (and headphone buttons) drive Spotify,
/// and shows the current track in macOS's Now Playing.
final class MediaKeys {
    private weak var player: PlayerWindowController?
    /// How many remote commands were actually wired up (shown on the loading screen).
    private(set) var registered = 0

    init(player: PlayerWindowController) {
        self.player = player
        let center = MPRemoteCommandCenter.shared()
        var tokens: [Any] = []

        tokens.append(center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player?.control("toggle")
            return .success
        })
        tokens.append(center.playCommand.addTarget { [weak self] _ in
            self?.player?.control("play")
            return .success
        })
        tokens.append(center.pauseCommand.addTarget { [weak self] _ in
            self?.player?.control("pause")
            return .success
        })
        tokens.append(center.nextTrackCommand.addTarget { [weak self] _ in
            self?.player?.control("next")
            return .success
        })
        tokens.append(center.previousTrackCommand.addTarget { [weak self] _ in
            self?.player?.control("prev")
            return .success
        })
        registered = tokens.count
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
