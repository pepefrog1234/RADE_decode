import SwiftUI

/// Displays a waterfall (spectrogram) — each row is one FFT frame,
/// colors represent signal strength. Uses Canvas for MVP.
struct WaterfallView: View {
    let history: [[Float]]
    
    private let minDB: Float = -100
    private let maxDB: Float = 0
    private let maxFreq: CGFloat = 3000
    private let nyquistFreq: CGFloat = 4000  // 8kHz sample rate / 2
    
    var body: some View {
        ZStack {
            Color.black
            
            Canvas { context, size in
                guard !history.isEmpty else { return }
                
                let rowCount = history.count
                let rowHeight = size.height / CGFloat(max(rowCount, 1))
                
                for (rowIndex, row) in history.enumerated() {
                    let y = CGFloat(rowIndex) * rowHeight
                    let totalBins = row.count
                    // Only display bins covering 0-3kHz (3/4 of Nyquist range)
                    let displayBins = totalBins * Int(maxFreq) / Int(nyquistFreq)
                    let binWidth = size.width / CGFloat(max(displayBins, 1))
                    
                    for (binIndex, value) in row.prefix(displayBins).enumerated() {
                        let x = CGFloat(binIndex) * binWidth
                        let normalized = Double(
                            (value - minDB) / (maxDB - minDB)
                        ).clamped(to: 0...1)
                        
                        let color = waterfallColor(normalized)
                        let rect = CGRect(x: x, y: y, width: binWidth + 1, height: rowHeight + 1)
                        context.fill(Path(rect), with: .color(color))
                    }
                }
                
                // Frequency reference lines to help tuning alignment
                let guideFreqs: [CGFloat] = [750, 1500, 2200]
                for freq in guideFreqs {
                    let x = freq / maxFreq * size.width
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.white.opacity(0.40)), lineWidth: 1.0)
                }
            }
        }
    }
    
    /// Maps a 0-1 normalized value to a waterfall color.
    /// Uses a perceptually smooth dark-blue -> blue -> cyan -> green -> yellow -> red -> white mapping.
    private func waterfallColor(_ value: Double) -> Color {
        if value < 0.15 {
            // Black to dark blue
            let t = value / 0.15
            return Color(red: 0, green: 0, blue: 0.15 + 0.35 * t)
        } else if value < 0.30 {
            // Dark blue to blue-cyan
            let t = (value - 0.15) / 0.15
            return Color(red: 0, green: 0.3 * t, blue: 0.5 + 0.5 * t)
        } else if value < 0.50 {
            // Blue-cyan to green
            let t = (value - 0.30) / 0.20
            return Color(red: 0, green: 0.3 + 0.7 * t, blue: 1.0 - t)
        } else if value < 0.70 {
            // Green to yellow
            let t = (value - 0.50) / 0.20
            return Color(red: t, green: 1.0, blue: 0)
        } else if value < 0.90 {
            // Yellow to red
            let t = (value - 0.70) / 0.20
            return Color(red: 1.0, green: 1.0 - t, blue: 0)
        } else {
            // Red to white
            let t = (value - 0.90) / 0.10
            return Color(red: 1.0, green: t * 0.8, blue: t * 0.6)
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    let history = (0..<100).map { _ in
        (0..<256).map { _ in Float.random(in: -90...(-10)) }
    }
    WaterfallView(history: history)
        .frame(height: 200)
}
