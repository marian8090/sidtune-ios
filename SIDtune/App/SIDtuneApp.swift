import SwiftUI

@main
struct SIDtuneApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.boot() }
                .onOpenURL { model.open($0) }
        }
        .commands { PlaybackCommands(model: model) }
    }
}

/// Hardware keyboard shortcuts on iPad, matching the web app's (src/ui/App.tsx) where iPadOS allows.
struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(model.playing ? "Pause" : "Play") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next Tune") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Button("Previous Tune") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Forward 10 Seconds") { model.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back 10 Seconds") { model.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Divider()
            Button("Volume Up") { model.setVolume(model.settings.volume + 0.05) }
                .keyboardShortcut("+", modifiers: [])
            Button("Volume Down") { model.setVolume(model.settings.volume - 0.05) }
                .keyboardShortcut("-", modifiers: [])
            Divider()
            Button("Shuffle") { model.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [])
            Button("Repeat") { model.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [])
            Button("Favorite") { if let t = model.current { model.toggleFavorite(t.path) } }
                .keyboardShortcut("f", modifiers: [])
            Divider()
            ForEach(1..<10) { n in
                Button("Subtune \(n)") { if n <= (model.details?.songs ?? 0) { model.selectSong(n - 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
        }
        CommandMenu("View") {
            Button("Now Playing") { model.nowPlayingOpen.toggle() }
                .keyboardShortcut("n", modifiers: [])
            Button("Audio Quality and Equalizer") { model.soundOpen.toggle() }
                .keyboardShortcut("e", modifiers: .control)
            Button("Next Theme") { model.cycleTheme(1) }
                .keyboardShortcut("t", modifiers: [])
            Button("Previous Theme") { model.cycleTheme(-1) }
                .keyboardShortcut("t", modifiers: .shift)
            Button("Settings") { model.settingsOpen = true }
                .keyboardShortcut(",", modifiers: .command)
            Button("Help") { model.helpOpen = true }
                .keyboardShortcut("?", modifiers: [])
        }
    }
}
