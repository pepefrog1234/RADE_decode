import SwiftUI

/// Displays a real-time audio spectrum using SwiftUI Canvas.
struct SpectrumView: View {
    let fftData: [Float]
    
    // Frequency range for RADE: 0 - 3000 Hz (modem band of interest)
    private let minDB: Float = -100
    private let maxDB: Float = 0
    private let maxFreq: CGFloat = 3000
    private let nyquistFreq: CGFloat = 4000  // 8kHz sample rate / 2
    
    var body: some View {
        ZStack {
            // Dark background
            Color.black
            
            // Grid lines
            Canvas { context, size in
                drawGrid(context: context, size: size)
            }
            
            // Spectrum fill + line
            Canvas { context, size in
                guard !fftData.isEmpty else { return }
                
                let width = size.width
                let height = size.height
                let totalBins = fftData.count
                // Only display bins covering 0-3kHz (3/4 of Nyquist range)
                let displayBins = totalBins * Int(maxFreq) / Int(nyquistFreq)
                
                // Build the spectrum path
                var linePath = Path()
                var fillPath = Path()
                
                fillPath.move(to: CGPoint(x: 0, y: height))
                
                for i in 0..<displayBins {
                    let x = CGFloat(i) / CGFloat(displayBins) * width
                    let normalized = CGFloat(
                        (fftData[i] - minDB) / (maxDB - minDB)
                    ).clamped(to: 0...1)
                    let y = height - (normalized * height)
                    
                    if i == 0 {
                        linePath.move(to: CGPoint(x: x, y: y))
                    } else {
                        linePath.addLine(to: CGPoint(x: x, y: y))
                    }
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                }
                
                // Close fill path
                fillPath.addLine(to: CGPoint(x: width, y: height))
                fillPath.closeSubpath()
                
                // Gradient fill under the curve
                context.fill(
                    fillPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.green.opacity(0.3),
                            Color.green.opacity(0.05)
                        ]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: height)
                    )
                )
                
                // Bright spectrum line
                context.stroke(linePath, with: .color(.green), lineWidth: 1.5)
            }
            
            // Frequency labels
            VStack {
                Spacer()
                HStack {
                    Text("0")
                    Spacer()
                    Text("1k")
                    Spacer()
                    Text("2k")
                    Spacer()
                    Text("3k")
                }
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(Color.gray.opacity(0.7))
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            
            // dB labels on left
            VStack {
                Text("0")
                Spacer()
                Text("-50")
                Spacer()
                Text("-100")
            }
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundColor(Color.gray.opacity(0.5))
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
        }
    }
    
    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let gridFreqs: [CGFloat] = [1000, 2000]
        let guideFreqs: [CGFloat] = [750, 1500, 2200]
        
        // Vertical frequency lines
        for freq in gridFreqs {
            let x = freq / maxFreq * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
        }
        
        // Reference guide lines for tuning alignment
        for freq in guideFreqs {
            let x = freq / maxFreq * size.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(.yellow.opacity(0.35)), lineWidth: 1.0)
        }
        
        // Horizontal dB lines
        let dbSteps: [Float] = [-20, -40, -60, -80, -100]
        for db in dbSteps {
            let normalized = CGFloat((db - minDB) / (maxDB - minDB))
            let y = size.height - (normalized * size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        }
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    SpectrumView(fftData: (0..<512).map { _ in Float.random(in: -90...(-10)) })
        .frame(height: 150)
}
