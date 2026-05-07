import SwiftUI

struct RecordingWaveformView: View {
    @EnvironmentObject private var theme: ThemeManager
    @ObservedObject var streamingState: StreamingTextState

    private let barCount = 5
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 2.5
    private let totalHeight: CGFloat = 24

    /// Minimum audio level required before bars visibly animate. Below this
    /// threshold we freeze the waveform at its resting height so silent
    /// intervals don't read as "the app is picking up phantom sound".
    private let silenceThreshold: CGFloat = 0.02
    private let minFraction: CGFloat = 0.15

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            let t = CGFloat(timeline.date.timeIntervalSinceReferenceDate)
            let isSilent = streamingState.audioLevel < silenceThreshold
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let barHeight: CGFloat = {
                        guard !isSilent else {
                            return max(totalHeight * minFraction, 4)
                        }
                        let phase = CGFloat(index) / CGFloat(barCount) * .pi * 2
                        let sineVal = sin(phase + t * 3) * 0.5 + 0.5
                        let amplitude = streamingState.audioLevel * 0.7 + minFraction
                        let fraction = minFraction + (1 - minFraction) * amplitude * sineVal
                        return max(totalHeight * fraction, 4)
                    }()

                    // Solid theme accent — no gradient. Bar height already
                    // conveys energy; a gradient on top added visual noise.
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(theme.waveformColor)
                        .frame(width: barWidth, height: barHeight)
                }
            }
            .frame(width: 44, height: totalHeight)
        }
    }
}
