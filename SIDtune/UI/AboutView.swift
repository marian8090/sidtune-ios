import SwiftUI

/// Port of src/ui/About.tsx. Shown at startup unless switched off.
struct AboutView: View {
    @Bindable var model: AppModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("SIDtune").appFont(.largeTitle).fontWeight(.heavy).foregroundStyle(theme.accentStrong)
                        Text(Bundle.main.version).appFont(.subheadline).foregroundStyle(theme.muted)
                    }
                    Text("A player for Commodore 64 SID music and the High Voltage SID Collection. It emulates the C64 and its SID sound chip cycle by cycle, so tunes sound the way they did on the real machine.")
                    Text("Everything runs on this device: the emulation, your library, playlists, favorites and settings. The only network traffic is the online catalogue and the tunes you play from it.")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Getting started").appFont(.headline)
                        bullet("The whole HVSC is in the Library when the online catalogue is on. Search by title, composer, year or path.")
                        bullet("Tap a tune to play it. Next and previous follow the list you started from.")
                        bullet("Swipe right on a tune to favorite it; long-press for playlists and sharing.")
                        bullet("The button with the mode name (Magic) picks the audio quality and equalizer.")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Credits").appFont(.headline)
                        Text("Emulation: libsidplayfp with reSIDfp and SIDLite, by Leandro Nini, Antti Lankila, Simon White and contributors (GPL-2.0-or-later).")
                        Text("Pet Me 64 and Print Char 21 fonts by Kreative Korp, used under the Kreative Software Relay Fonts Free Use License.")
                        Text("Inspired by ultraSID by Toddler-Boy. SIDtune is an independent project.")
                        Text("The music belongs to its composers. HVSC is a volunteer archive.")
                    }
                    .appFont(.footnote)
                    .foregroundStyle(theme.muted)

                    Toggle("Show this at startup", isOn: $model.settings.showWelcome)
                }
                .appFont(.body)
                .foregroundStyle(theme.text)
                .padding(24)
            }
            .background(theme.bg2)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Start listening") { dismiss() } }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Help") {
                        dismiss()
                        model.helpOpen = true
                    }
                }
            }
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(theme.accentStrong)
            Text(s)
        }
    }
}

/// The bundled manual or changelog, rendered from Markdown (headings, paragraphs, lists, tables, inline styles).
/// Port of src/ui/DocDialog.tsx + src/lib/markdown.ts.
struct DocView: View {
    let title: String
    let resource: String
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
                .foregroundStyle(theme.text)
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(theme.bg2)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case table([[String]])
    }

    private var blocks: [Block] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [Block] = []
        var para: [String] = []
        var table: [[String]] = []
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))) }
            if !table.isEmpty { out.append(.table(table)) }
            para = []
            table = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                out.append(.heading(level, String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("|") {
                if !para.isEmpty { flush() }
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
            } else if line.hasPrefix("- ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if raw.hasPrefix("  "), case .bullet(let prev) = out.last, para.isEmpty {
                out[out.count - 1] = .bullet(prev + " " + line)
            } else {
                para.append(line)
            }
        }
        flush()
        return out
    }

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(md(s)).appFont(level == 1 ? .title : level == 2 ? .title3 : .headline).fontWeight(.bold).padding(.top, level == 1 ? 0 : 10)
        case .paragraph(let s):
            Text(md(s)).appFont(.body)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(theme.accentStrong)
                Text(md(s)).appFont(.body)
            }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(md(cell)).appFont(.callout).fontWeight(i == 0 ? .semibold : .regular)
                        }
                    }
                    if i == 0 { Divider() }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.panel))
        }
    }
}
