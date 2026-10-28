import SwiftUI

/// Bottom bar: the full transport on iPad, a mini player on iPhone. Port of src/ui/PlayerBar.tsx.
struct PlayerBar: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        Group {
            if hSize == .compact {
                compact
            } else {
                regular
            }
        }
        .background(theme.bg2)
        .overlay(alignment: .top) { Rectangle().fill(theme.text.opacity(0.1)).frame(height: 1) }
    }

    private var compact: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Rectangle().fill(theme.accentStrong)
                    .frame(width: geo.size.width * progress)
            }
            .frame(height: 2)
            HStack(spacing: 12) {
                Button { if model.current != nil { model.nowPlayingOpen = true } } label: {
                    HStack(spacing: 10) {
                        TuneTitle(model: model)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open now playing")
                PlayButton(model: model, size: 22)
                Button { model.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                    .accessibilityLabel("Next")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var progress: Double {
        model.duration > 0 ? min(1, model.position / model.duration) : 0
    }

    private var regular: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                Button { if model.current != nil { model.nowPlayingOpen.toggle() } } label: {
                    HStack(spacing: 10) {
                        TuneTitle(model: model)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let t = model.current {
                    Button { model.toggleFavorite(t.path) } label: {
                        Image(systemName: model.isFavorite(t.path) ? "heart.fill" : "heart")
                    }
                    .accessibilityLabel(model.isFavorite(t.path) ? "Remove from favorites" : "Add to favorites")
                }
            }
            .frame(minWidth: 180, maxWidth: 280, alignment: .leading)

            VStack(spacing: 6) {
                Transport(model: model)
                SeekBar(model: model)
            }
            .frame(maxWidth: 560)

            HStack(spacing: 14) {
                SoundButton(model: model)
                VolumeSlider(model: model).frame(width: 110)
                Button { model.nowPlayingOpen.toggle() } label: { Image(systemName: "sidebar.right") }
                    .disabled(model.current == nil)
                    .accessibilityLabel("Now playing")
            }
            .frame(minWidth: 180, maxWidth: 280, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct TuneTitle: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.current?.title ?? "Nothing playing")
                .appFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Text(model.current.map { t in model.details.map { $0.songs > 1 ? "\(t.author) · \(model.songIndex + 1)/\($0.songs)" : t.author } ?? t.author } ?? "Pick a tune")
                .appFont(.caption)
                .foregroundStyle(theme.muted)
                .lineLimit(1)
        }
    }
}

struct PlayButton: View {
    let model: AppModel
    var size: CGFloat = 26
    @Environment(\.theme) private var theme

    var body: some View {
        Button { model.togglePlay() } label: {
            ZStack {
                if model.loading || model.busy || model.seeking {
                    ProgressView().tint(theme.accentInk)
                } else {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.7, weight: .bold))
                        .foregroundStyle(theme.accentInk)
                        .offset(x: model.playing ? 0 : size * 0.05)
                }
            }
            .frame(width: size * 1.7, height: size * 1.7)
            .background(Circle().fill(theme.accentStrong))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.playing ? "Pause" : "Play")
    }
}

struct Transport: View {
    let model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 22) {
            Button { model.toggleShuffle() } label: {
                ModeIcon(systemName: "shuffle", on: model.settings.shuffle)
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(model.settings.shuffle ? "on" : "off")
            Button { model.previous() } label: { Image(systemName: "backward.fill").font(.title3) }
                .accessibilityLabel("Previous")
            PlayButton(model: model)
            Button { model.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                .accessibilityLabel("Next")
            Button { model.cycleRepeat() } label: {
                ModeIcon(systemName: model.settings.repeatMode == .one ? "repeat.1" : "repeat", on: model.settings.repeatMode != .off)
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(model.settings.repeatMode.rawValue)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.text)
    }
}

/// Shuffle and repeat: a filled circle when on, so the state reads at a glance in every theme.
private struct ModeIcon: View {
    let systemName: String
    let on: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(on ? theme.accentInk : theme.muted)
            .frame(width: 34, height: 34)
            .background(Circle().fill(on ? theme.accentStrong : .clear))
            .contentShape(Circle())
    }
}

struct SeekBar: View {
    let model: AppModel
    @Environment(\.theme) private var theme
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(dragging ?? model.position))
                .frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { dragging ?? min(model.position, model.duration) }, set: { dragging = $0 }),
                in: 0...max(1, model.duration)
            ) { editing in
                if !editing, let d = dragging {
                    model.seek(d)
                    dragging = nil
                }
            }
            .disabled(model.current == nil)
            .accessibilityLabel("Position")
            Text(model.lengthKnown || model.current == nil ? formatTime(model.duration) : "~" + formatTime(model.duration))
                .frame(width: 44, alignment: .leading)
        }
        .appFont(.caption)
        .monospacedDigit()
        .foregroundStyle(theme.muted)
    }
}

struct VolumeSlider: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.settings.volume == 0 ? "speaker.slash.fill" : "speaker.fill").font(.caption)
            Slider(value: Binding(get: { model.settings.volume }, set: { model.setVolume($0) }), in: 0...1)
                .accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill").font(.caption)
        }
    }
}

/// Opens the audio quality and equalizer panel, labelled with the current mode like the web app's sound button.
struct SoundButton: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        Button { model.soundOpen.toggle() } label: {
            Text(model.settings.fxMode.label)
                .appFont(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.panel2))
                .overlay(Capsule().stroke(theme.accentStrong.opacity(0.6)))
                .foregroundStyle(theme.text)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Audio quality: \(model.settings.fxMode.label)")
        .popover(isPresented: $model.soundOpen) {
            SoundView(model: model)
                .frame(minWidth: 340, minHeight: 520)
                .presentationCompactAdaptation(.sheet)
        }
    }
}
