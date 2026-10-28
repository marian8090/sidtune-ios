import SwiftUI

/// Scrolling piano roll of what the three voices of each SID chip are doing, plus a scope and the filter settings.
/// Port of src/ui/Viz.tsx.
struct VizView: View {
    let model: AppModel
    var compact = false
    @Environment(\.theme) private var theme
    @State private var history = VizHistory()

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(paused: !model.playing)) { timeline in
                Canvas { ctx, size in
                    history.advance(model: model, at: timeline.date)
                    drawRoll(ctx, size)
                }
            }
            .frame(height: compact ? 96 : 150)
            .background(theme.vizBg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            TimelineView(.animation(paused: !model.playing)) { _ in
                Canvas { ctx, size in drawScope(ctx, size) }
            }
            .frame(height: compact ? 34 : 56)
            .background(theme.vizBg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                Text(filterInfo)
                    .appFont(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Visualiser")
    }

    private func drawRoll(_ ctx: GraphicsContext, _ size: CGSize) {
        let step: CGFloat = 2
        let columns = history.columns
        let lanes = max(1, history.lanes)
        let laneH = size.height / CGFloat(lanes)
        for lane in 1..<lanes {
            ctx.fill(Path(CGRect(x: 0, y: CGFloat(lane) * laneH - 0.5, width: size.width, height: 1)), with: .color(theme.text.opacity(0.07)))
        }
        let visible = min(columns.count, Int(size.width / step) + 1)
        for i in 0..<visible {
            let col = columns[columns.count - 1 - i]
            let x = size.width - CGFloat(i + 1) * step
            for note in col where note.lane < lanes {
                let top = CGFloat(note.lane) * laneH
                let y = top + CGFloat(1 - note.pitch) * (laneH - 4)
                ctx.fill(Path(CGRect(x: x, y: y, width: step, height: 3)),
                         with: .color(theme.waveColor(note.wave).opacity(note.gate ? 1 : 0.25)))
            }
        }
    }

    private func drawScope(_ ctx: GraphicsContext, _ size: CGSize) {
        let wave = model.recentSamples(2048)
        guard wave.count > 4 else { return }
        // Trigger on a rising zero crossing so the trace holds still.
        var start = 0
        for i in 1..<(wave.count / 2) where wave[i - 1] < 0 && wave[i] >= 0 {
            start = i
            break
        }
        let n = wave.count / 2
        var path = Path()
        for i in 0..<n {
            let x = CGFloat(i) / CGFloat(n) * size.width
            let y = size.height / 2 - CGFloat(wave[start + i]) * size.height * 0.9
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.stroke(path, with: .color(theme.vizScope), lineWidth: 1.5)
    }

    private var filterInfo: String {
        guard model.current != nil, let g = model.currentRegisters()?.first, g.count >= 25 else { return " " }
        let cutoff = Int(g[21] & 7) | Int(g[22]) << 3
        let modes = [(0x10, "LP"), (0x20, "BP"), (0x40, "HP")].filter { Int(g[24]) & $0.0 != 0 }.map(\.1)
        return "filter \(modes.isEmpty ? "off" : modes.joined(separator: "+")) · cutoff \(cutoff) · res \(g[23] >> 4) · vol \(g[24] & 15)"
    }
}

/// Columns of the piano roll, newest last. A class so the Canvas can append to it while drawing.
@MainActor
final class VizHistory {
    struct Note {
        var lane: Int
        /// 0 (low) to 1 (high), MIDI 24…108.
        var pitch: Double
        var wave: Int
        var gate: Bool
    }

    private(set) var columns: [[Note]] = []
    private(set) var lanes = 3
    private var last = Date.distantPast

    func advance(model: AppModel, at date: Date) {
        // About 60 columns a second, whatever the display's refresh rate.
        guard date.timeIntervalSince(last) >= 1.0 / 60 else { return }
        last = date
        guard let regs = model.currentRegisters(), !regs.isEmpty else { return }
        let clock = model.current?.clock == "NTSC" ? 1_022_730.0 : 985_248.0
        lanes = regs.count * 3
        var col: [Note] = []
        for (chip, rg) in regs.enumerated() where rg.count >= 25 {
            for v in 0..<3 {
                let b = v * 7
                let freq = Int(rg[b]) | Int(rg[b + 1]) << 8
                let ctl = Int(rg[b + 4])
                if freq == 0 || ctl & 0x08 != 0 { continue }
                let hz = Double(freq) * clock / 16_777_216
                let midi = 69 + 12 * log2(hz / 440)
                col.append(Note(lane: chip * 3 + v, pitch: min(1, max(0, (midi - 24) / 84)), wave: (ctl >> 4) & 0x0F, gate: ctl & 1 != 0))
            }
        }
        columns.append(col)
        if columns.count > 600 { columns.removeFirst(columns.count - 600) }
    }
}
