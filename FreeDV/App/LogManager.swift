import Foundation
import Combine
import os.log

private let backgroundLogger = OSLog(subsystem: "yakumo2683.FreeDV", category: "background")

/// Singleton log manager that captures diagnostic messages for in-app display.
/// Also writes to a persistent file so logs survive app termination.
class LogManager: ObservableObject {
    static let shared = LogManager()
    
    /// Maximum number of log lines to keep in memory
    private let maxLines = 500
    
    /// All captured log lines
    @Published var lines: [String] = []
    
    /// When true, skip in-memory @Published updates to avoid SwiftUI diffing in background
    var backgroundMode: Bool = false
    
    private let queue = DispatchQueue(label: "com.freedv.log", qos: .utility)
    
    /// File handle for persistent background log
    private var fileHandle: FileHandle?
    private let logFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("freedv_background.log")
    }()
    
    /// Previous session's log (loaded on init, shown in UI)
    @Published var previousSessionLog: String = ""
    
    private init() {
        // Load previous session log before we overwrite it
        if let data = try? Data(contentsOf: logFileURL),
           let text = String(data: data, encoding: .utf8) {
            previousSessionLog = text
        }
        
        // Start fresh log file for this session
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }
    
    /// Add a log message (thread-safe, updates UI on main thread)
    func log(_ message: String) {
        // In background, keep only explicit background lifecycle logs.
        // This avoids heavy I/O from high-frequency DSP diagnostics.
        if backgroundMode && !message.hasPrefix("[BG]") {
            return
        }

        let timestamp = Self.timeFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        
        // Always print to console for Xcode debugging
        print(entry)
        
        // Write to persistent file (survives app kill)
        queue.async {
            if let data = (entry + "\n").data(using: .utf8) {
                self.fileHandle?.write(data)
            }
        }
        
        // Update in-memory log for UI display — skip in background to avoid
        // triggering SwiftUI view body re-evaluation for invisible views.
        if !backgroundMode {
            DispatchQueue.main.async {
                self.lines.append(entry)
                if self.lines.count > self.maxLines {
                    self.lines.removeFirst(self.lines.count - self.maxLines)
                }
            }
        }
    }
    
    /// Log a critical background event (also goes to os_log which persists in system log)
    func logBackground(_ message: String) {
        os_log(.error, log: backgroundLogger, "%{public}@", message)
        log("[BG] \(message)")
    }
    
    /// Clear all logs
    func clear() {
        DispatchQueue.main.async {
            self.lines.removeAll()
        }
    }
    
    /// Export all logs as a single string
    func exportText() -> String {
        lines.joined(separator: "\n")
    }
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Convenience global function
func appLog(_ message: String) {
    LogManager.shared.log(message)
}

/// Log a critical background lifecycle event (persists in os_log + file)
func bgLog(_ message: String) {
    LogManager.shared.logBackground(message)
}
