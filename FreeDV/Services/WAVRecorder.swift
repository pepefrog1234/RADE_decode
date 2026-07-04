import Foundation

/// Records 16 kHz Int16 mono PCM audio to a WAV file.
/// Captures decoded speech output from FARGAN vocoder.
class WAVRecorder {
    private var fileHandle: FileHandle?
    private var totalSamples: UInt32 = 0
    private let sampleRate: UInt32
    private let bitsPerSample: UInt16 = 16
    private let channels: UInt16 = 1
    private(set) var currentFilename: String?

    /// Default 16 kHz (decoded speech); pass 8000 for modem waveforms.
    init(sampleRate: UInt32 = 16000) {
        self.sampleRate = sampleRate
    }
    
    func start(filename: String) throws {
        let url = Self.recordingsDirectory.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
        currentFilename = filename
        totalSamples = 0
        
        // Write WAV header placeholder (will be updated on stop)
        writeWAVHeader(dataSize: 0)
        appLog("WAVRecorder: started \(filename)")
    }
    
    /// Write 8kHz Int16 samples. Called from processingQueue.
    func writeSamples(_ samples: UnsafePointer<Int16>, count: Int) {
        guard let fh = fileHandle, count > 0 else { return }
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        try? fh.write(contentsOf: data)
        totalSamples += UInt32(count)
    }
    
    func stop() -> Int64 {
        guard let fh = fileHandle else { return 0 }
        
        // Update WAV header with final data size
        let dataSize = totalSamples * UInt32(bitsPerSample / 8) * UInt32(channels)
        fh.seek(toFileOffset: 4)
        writeUInt32(36 + dataSize)
        fh.seek(toFileOffset: 40)
        writeUInt32(dataSize)
        
        fh.closeFile()
        fileHandle = nil
        
        let fileSize = Int64(44 + dataSize)  // header + data
        appLog("WAVRecorder: stopped, \(totalSamples) samples, \(fileSize) bytes")
        return fileSize
    }
    
    // MARK: - WAV Header
    
    private func writeWAVHeader(dataSize: UInt32) {
        guard let fh = fileHandle else { return }
        
        var header = Data()
        
        // RIFF chunk
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32: 36 + dataSize)    // chunk size
        header.append(contentsOf: "WAVE".utf8)
        
        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32: 16)               // sub-chunk size
        header.append(uint16: 1)                // PCM format
        header.append(uint16: channels)
        header.append(uint32: sampleRate)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        header.append(uint32: byteRate)
        let blockAlign = channels * (bitsPerSample / 8)
        header.append(uint16: blockAlign)
        header.append(uint16: bitsPerSample)
        
        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        header.append(uint32: dataSize)
        
        try? fh.write(contentsOf: header)
    }
    
    private func writeUInt32(_ value: UInt32) {
        guard let fh = fileHandle else { return }
        var data = Data()
        data.append(uint32: value)
        try? fh.write(contentsOf: data)
    }
    
    // MARK: - Directory
    
    static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    /// Calculate total size of all recordings in bytes.
    static var totalRecordingsSize: Int64 {
        let dir = recordingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        
        return files.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }
}

// MARK: - Data helpers for little-endian WAV writing

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    
    mutating func append(uint32 value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
