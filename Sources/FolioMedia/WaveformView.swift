import AVFoundation
import SwiftUI
import FolioKit

/// Audio waveform: click to seek, drag to select a range for trim and export.
struct WaveformView: View {
    @Bindable var controller: MediaController
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let total = max(controller.duration.seconds, .ulpOfOne)
            Canvas { context, size in
                draw(in: &context, size: size, total: total)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let a = fraction(g.startLocation.x, width: geo.size.width)
                        let b = fraction(g.location.x, width: geo.size.width)
                        guard abs(g.translation.width) > 3 else { return }
                        controller.selection = MediaMath.clamp(from: time(a * total), to: time(b * total), within: controller.duration)
                    }
                    .onEnded { g in
                        if abs(g.translation.width) <= 3 { controller.seek(toFraction: fraction(g.location.x, width: geo.size.width)) }
                    }
            )
        }
        .overlay {
            if controller.peaks == nil {
                if let message = controller.waveformMessage {
                    Text(message).font(.system(size: 13)).foregroundStyle(Hero.muted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform")
        .accessibilityValue("Playhead at \(MediaMath.timecode(time(controller.currentTime))). \(InfoFormat.selection(controller.selection))")
        .accessibilityHint("Drag to select. Adjust to move the playhead by five seconds.")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 5.0 : -5.0
            controller.seek(toFraction: (controller.currentTime + delta) / max(controller.duration.seconds, 1))
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, total: Double) {
        if let selection = controller.selection {
            let x0 = selection.start.seconds / total * size.width, x1 = selection.end.seconds / total * size.width
            context.fill(Path(roundedRect: CGRect(x: x0, y: 0, width: x1 - x0, height: size.height), cornerRadius: Hero.Radius.md), with: .color(Hero.accentSoft))
        }
        if let peaks = controller.peaks, !peaks.isEmpty {
            // One bar per 3 pt, each the loudest of the bins it covers.
            let bars = max(1, Int(size.width / 3))
            let mid = size.height / 2
            // Scale so the loudest moment fills the height; quiet speech is otherwise a flat line.
            let gain = 1 / CGFloat(max(peaks.max() ?? 1, 0.05))
            for bar in 0..<bars {
                let lo = bar * peaks.count / bars, hi = max(lo + 1, (bar + 1) * peaks.count / bars)
                let peak = CGFloat(peaks[lo..<min(hi, peaks.count)].max() ?? 0) * gain
                let h = max(1, peak * (size.height - 8))
                let x = CGFloat(bar) * 3
                let seconds = Double(x) / size.width * total
                let selected = controller.selection.map { seconds >= $0.start.seconds && seconds <= $0.end.seconds } ?? false
                context.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: 2, height: h), cornerRadius: 1),
                             with: .color(selected ? Hero.accent : Hero.muted.opacity(0.7)))
            }
        }
        let playhead = controller.currentTime / total * size.width
        context.fill(Path(CGRect(x: playhead - 0.5, y: 0, width: 1, height: size.height)), with: .color(Hero.foreground))
    }

    private func fraction(_ x: CGFloat, width: CGFloat) -> Double { Double(max(0, min(1, x / max(width, 1)))) }
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
}

/// Thumbnails across the bottom of a video; click one to jump there.
struct FilmstripView: View {
    let controller: MediaController

    var body: some View {
        HStack(spacing: 2) {
            ForEach(controller.thumbnails.indices, id: \.self) { index in
                let fraction = (Double(index) + 0.5) / Double(controller.thumbnails.count)
                Button { controller.seek(toFraction: fraction) } label: {
                    Rectangle()
                        .fill(Hero.default)
                        .overlay {
                            if let image = controller.thumbnails[index] {
                                Image(decorative: image, scale: 2).resizable().scaledToFill()
                            }
                        }
                        .clipShape(.rect(cornerRadius: Hero.Radius.sm))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to \(MediaMath.timecode(CMTime(seconds: fraction * controller.duration.seconds, preferredTimescale: 600)))")
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Hero.surface)
        .overlay(alignment: .top) { Rectangle().fill(Hero.separator).frame(height: 1) }
    }
}

/// Progress HUD for exports, with Cancel (also Esc).
struct ExportHUD: View {
    let job: MediaController.Job
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Hero.foreground).lineLimit(1).truncationMode(.middle)
            ProgressView(value: job.fraction).tint(Hero.accent)
            HStack {
                Text("\(Int(job.fraction * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(Hero.muted)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(.hero(.tertiary, size: .sm))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .heroOverlay(cornerRadius: Hero.Radius.xxxl)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.title)
        .accessibilityValue("\(Int(job.fraction * 100)) percent")
    }
}
