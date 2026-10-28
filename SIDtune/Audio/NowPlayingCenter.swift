import MediaPlayer

/// Lock screen, Control Center, headphone and CarPlay controls. Replaces the web app's media-anchor.ts + Media Session code.
@MainActor
final class NowPlayingCenter {
    private weak var model: AppModel?

    func attach(_ model: AppModel) {
        self.model = model
        let c = MPRemoteCommandCenter.shared()
        add(c.playCommand) { m, _ in if !m.playing { m.togglePlay() } }
        add(c.pauseCommand) { m, _ in if m.playing { m.togglePlay() } }
        add(c.togglePlayPauseCommand) { m, _ in m.togglePlay() }
        add(c.nextTrackCommand) { m, _ in m.next() }
        add(c.previousTrackCommand) { m, _ in m.previous() }
        add(c.changePlaybackPositionCommand) { m, event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { m.seek(e.positionTime) }
        }
        add(c.likeCommand) { m, _ in if let t = m.current { m.toggleFavorite(t.path) } }
        c.likeCommand.localizedTitle = "Favorite"
    }

    /// Remote commands arrive on the main thread.
    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AppModel, MPRemoteCommandEvent) -> Void) {
        command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return .commandFailed }
                action(model, event)
                return .success
            }
        }
    }

    func update(force: Bool = false) {
        guard let model else { return }
        let center = MPNowPlayingInfoCenter.default()
        guard let t = model.current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.songs > 1 ? "\(t.title) (\(model.songIndex + 1)/\(t.songs))" : t.title,
            MPMediaItemPropertyArtist: t.author,
            MPMediaItemPropertyAlbumTitle: t.released,
            MPMediaItemPropertyPlaybackDuration: model.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.position,
            MPNowPlayingInfoPropertyPlaybackRate: model.playing ? 1.0 : 0.0,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        center.nowPlayingInfo = info
        center.playbackState = model.playing ? .playing : .paused
        MPRemoteCommandCenter.shared().likeCommand.isActive = model.isFavorite(t.path)
    }
}
