import Foundation

/// Stores decoded feature frames to disk while app is in background.
/// Frames are written as raw little-endian Float32 values, contiguous.
final class DeferredFeatureStore {
    private let fileManager = FileManager.default

    private var fileHandle: FileHandle?

    private var fileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("deferred_features.bin")
    }

    func reset() {
        fileHandle?.closeFile()
        fileHandle = nil
        try? fileManager.removeItem(at: fileURL)
    }

    private func ensureWriter() -> FileHandle? {
        if fileHandle == nil {
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
        }
        return fileHandle
    }

    func append(frames: [[Float]]) {
        guard !frames.isEmpty else { return }
        guard let handle = ensureWriter() else { return }

        var data = Data()
        data.reserveCapacity(frames.count * frames[0].count * MemoryLayout<Float32>.size)

        for frame in frames {
            for value in frame {
                var le = Float32(value).bitPattern.littleEndian
                Swift.withUnsafeBytes(of: &le) { bytes in
                    data.append(contentsOf: bytes)
                }
            }
        }

        handle.write(data)
    }

    /// Fast path for background decode: append contiguous Float features directly.
    /// This avoids building nested frame arrays on the hot DSP path.
    func appendRawFloats(_ values: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        guard let handle = ensureWriter() else { return }
        let data = Data(bytes: values, count: count * MemoryLayout<Float>.size)
        handle.write(data)
    }

    func drain(frameWidth: Int, batchFrames: Int, process: ([[Float]]) -> Void) {
        guard frameWidth > 0, batchFrames > 0 else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        fileHandle?.closeFile()
        fileHandle = nil

        guard let reader = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer {
            try? reader.close()
            try? fileManager.removeItem(at: fileURL)
        }

        let bytesPerFrame = frameWidth * MemoryLayout<Float32>.size
        let chunkBytes = bytesPerFrame * batchFrames

        while true {
            guard let chunk = try? reader.read(upToCount: chunkBytes),
                  !chunk.isEmpty else {
                break
            }

            let usableBytes = (chunk.count / bytesPerFrame) * bytesPerFrame
            if usableBytes == 0 { break }
            let usable = chunk.prefix(usableBytes)

            let floatCount = usable.count / MemoryLayout<Float32>.size
            var values = [Float](repeating: 0, count: floatCount)
            _ = values.withUnsafeMutableBytes { dst in
                usable.copyBytes(to: dst)
            }

            var frames: [[Float]] = []
            frames.reserveCapacity(floatCount / frameWidth)
            var idx = 0
            while idx + frameWidth <= values.count {
                frames.append(Array(values[idx..<(idx + frameWidth)]))
                idx += frameWidth
            }

            if !frames.isEmpty {
                process(frames)
            }

            if usableBytes < chunkBytes {
                break
            }
        }
    }
}
