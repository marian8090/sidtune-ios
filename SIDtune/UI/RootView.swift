import SwiftUI

/// iPad: sidebar + track list, Now Playing as an inspector column, full transport along the bottom.
/// iPhone: the same split view collapses to a stack, with a mini player and Now Playing as a sheet.
struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let theme = model.settings.theme.theme
        NavigationSplitView {
            SidebarView(model: model, selection: Binding(get: { model.view }, set: { if let v = $0 { model.view = v } }))
        } detail: {
            NavigationStack {
                TrackListView(model: model)
            }
        }
        .inspector(isPresented: hSize == .compact ? .constant(false) : $model.nowPlayingOpen) {
            NowPlayingView(model: model)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        // Outside the inspector, so the transport spans the whole window even with Now Playing open.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBar(model: model)
        }
        .sheet(isPresented: hSize == .compact ? $model.nowPlayingOpen : .constant(false)) {
            NowPlayingView(model: model)
                .presentationDragIndicator(.visible)
                .environment(\.theme, theme)
                .environment(\.fontID, model.settings.font)
        }
        .sheet(isPresented: $model.settingsOpen) { themed(SettingsView(model: model)) }
        .sheet(isPresented: $model.aboutOpen) { themed(AboutView(model: model)) }
        .sheet(isPresented: $model.helpOpen) { themed(DocView(title: "Help", resource: "MANUAL")) }
        .overlay(alignment: .top) { Banner(model: model) }
        .tint(theme.accentStrong)
        .environment(\.theme, theme)
        .environment(\.fontID, model.settings.font)
        .font(model.settings.font.font(.body))
        .preferredColorScheme(theme.colorScheme)
        .background(theme.bg)
    }

    private func themed(_ v: some View) -> some View {
        v.environment(\.theme, model.settings.theme.theme)
            .environment(\.fontID, model.settings.font)
            .tint(model.settings.theme.theme.accentStrong)
            .preferredColorScheme(model.settings.theme.theme.colorScheme)
    }
}

/// Short status messages ("Added 12 tunes."), like the web app's toast.
private struct Banner: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        if let text = model.message {
            Text(text)
                .appFont(.subheadline)
                .foregroundStyle(theme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(theme.panel2).shadow(radius: 8))
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.message = nil }
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    if model.message == text { withAnimation { model.message = nil } }
                }
        }
    }
}
