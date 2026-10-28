import SIDFX
import SwiftUI

/// Audio quality modes and the 3-band equalizer. Port of src/ui/SoundMenu.tsx.
struct SoundView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private static let bands = ["Low · 200 Hz", "Mid · 1 kHz", "High · 4 kHz"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Audio quality") {
                    ForEach(FxMode.allCases) { mode in
                        Button {
                            model.settings.fxMode = mode
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.label).appFont(.body).fontWeight(.semibold).foregroundStyle(theme.text)
                                    Text(mode.blurb).appFont(.footnote).foregroundStyle(theme.muted)
                                }
                                Spacer()
                                if model.settings.fxMode == mode {
                                    Image(systemName: "checkmark").foregroundStyle(theme.accentStrong)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.settings.fxMode == mode ? .isSelected : [])
                    }
                }
                .listRowBackground(theme.panel)

                Section {
                    ForEach(0..<3, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Self.bands[i]).appFont(.subheadline)
                                Spacer()
                                Text(String(format: "%@%.1f dB", model.settings.eq[i] > 0 ? "+" : "", model.settings.eq[i]))
                                    .appFont(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(theme.muted)
                            }
                            Slider(value: Binding(get: { model.settings.eq[i] }, set: { model.settings.eq[i] = ($0 * 2).rounded() / 2 }), in: -12...12)
                                .accessibilityLabel("\(Self.bands[i]) gain")
                        }
                    }
                } header: {
                    HStack {
                        Text("Equalizer")
                        Spacer()
                        Button("Reset") { model.settings.eq = [0, 0, 0] }
                            .disabled(model.settings.eq.allSatisfy { $0 == 0 })
                            .textCase(nil)
                    }
                }
                .listRowBackground(theme.panel)
            }
            .scrollContentBackground(.hidden)
            .background(theme.bg2)
            .navigationTitle("Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
