import SwiftUI

struct RecordingWaveformView: View {
    @State private var time: TimeInterval = 0

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 14
    private let minHeight: CGFloat = 3
    private let totalWidth: CGFloat = 44
    private let totalHeight: CGFloat = 24

    /// Waveform color: light blue
    private let waveRed: Double = 0.53
    private let waveGreen: Double = 0.76
    private let waveBlue: Double = 0.94

    private let timer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let heightRatio = self.heightRatio(for: index)
                let barHeight = minHeight + (maxHeight - minHeight) * heightRatio
                let alpha = 0.6 + 0.4 * heightRatio

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(
                        Color(
                            red: waveRed,
                            green: waveGreen,
                            blue: waveBlue,
                            opacity: alpha
                        )
                    )
                    .frame(width: barWidth, height: barHeight)
            }
        }
        .frame(width: totalWidth, height: totalHeight)
        .onReceive(timer) { _ in
            time += 0.06
        }
    }

    // MARK: - Waveform Math

    /// Computes the normalised height (0...1) for a given bar index using a sine wave.
    ///
    /// Formula: `sin(phase) * 0.5 + 0.5` where `phase = time * 4.0 + barIndex * 0.9`
    /// Each bar adds a phase offset of 0.9 radians so the wave ripples across the bars.
    private func heightRatio(for index: Int) -> CGFloat {
        let phase = time * 4.0 + Double(index) * 0.9
        return CGFloat(sin(phase) * 0.5 + 0.5)
    }
}
