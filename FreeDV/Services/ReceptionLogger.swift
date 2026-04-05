import Foundation
import SwiftData

/// Records signal quality data during each reception session.
/// All data is buffered in memory and only persisted to SwiftData
/// in endSession() if the session has meaningful data.
class ReceptionLogger {
    private let modelContext: ModelContext
    private(set) var currentSession: ReceptionSession?
    
    // In-memory buffers — nothing written to SwiftData until endSession()
    private var snapshotBuffer: [SignalSnapshot] = []
    private var syncEventBuffer: [SyncEvent] = []
    private var callsignEventBuffer: [CallsignEvent] = []
    
    private var lastSyncState: Int = 0
    private var snrSum: Float = 0
    private var snrCount: Int = 0
    
    /// When true, endSession() buffers completed sessions instead of persisting.
    /// Used during deferred decode so log entries only appear after the full decode finishes.
    var deferPersistence = false
    
    /// Sessions waiting to be persisted (accumulated while deferPersistence is true).
    private var deferredSessions: [(session: ReceptionSession, snapshots: [SignalSnapshot],
                                    syncEvents: [SyncEvent], callsignEvents: [CallsignEvent])] = []
    
    /// Minimum synced frames required to keep a session.
    /// At ~8 frames/sec, 4 frames ≈ 0.5 seconds — filters only very brief false syncs.
    private let minSyncedFrames = 4
    
    init(modelContainer: ModelContainer) {
        // Keep SwiftData context bound to main queue to avoid queue unbinding warnings.
        if Thread.isMainThread {
            self.modelContext = ModelContext(modelContainer)
        } else {
            var context: ModelContext?
            DispatchQueue.main.sync {
                context = ModelContext(modelContainer)
            }
            self.modelContext = context!
        }
    }
    
    // MARK: - Session Lifecycle
    
    func beginSession(audioDevice: String, sampleRate: Int) {
        let session = ReceptionSession(
            audioDevice: audioDevice,
            sampleRateHz: sampleRate
        )
        currentSession = session
        lastSyncState = 0
        snrSum = 0
        snrCount = 0
        snapshotBuffer.removeAll(keepingCapacity: true)
        syncEventBuffer.removeAll(keepingCapacity: true)
        callsignEventBuffer.removeAll(keepingCapacity: true)
        
        // Session stays in memory — NOT inserted into SwiftData yet
        appLog("ReceptionLogger: session started, device=\(audioDevice)")
    }
    
    func endSession(endTime: Date? = nil) {
        guard let session = currentSession else { return }
        
        session.endTime = endTime ?? Date()
        
        // Calculate average SNR from synced frames
        if snrCount > 0 {
            session.avgSNR = snrSum / Float(snrCount)
        }
        
        // Discard session if too few synced frames (likely false sync).
        // Keep sessions with callsign or decoded audio evidence.
        let hasDecodedAudio = session.audioFileSize > 44
            || (session.audioFilename != nil && session.audioFileSize > 0)
        if session.syncedFrames < minSyncedFrames
            && callsignEventBuffer.isEmpty
            && !hasDecodedAudio {
            appLog("ReceptionLogger: session discarded (syncedFrames=\(session.syncedFrames) < \(minSyncedFrames), no callsign)")
            discardSession()
            return
        }
        
        // Delete WAV file if it's empty (no decoded audio was written)
        if let filename = session.audioFilename {
            let url = WAVRecorder.recordingsDirectory.appendingPathComponent(filename)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64, size <= 44 {
                try? FileManager.default.removeItem(at: url)
                session.audioFilename = nil
                session.audioFileSize = 0
            }
        }
        
        // When deferring, stash the session and buffers for later persistence
        if deferPersistence {
            deferredSessions.append((session: session, snapshots: snapshotBuffer,
                                     syncEvents: syncEventBuffer, callsignEvents: callsignEventBuffer))
            appLog("ReceptionLogger: session deferred, frames=\(session.totalModemFrames) (total deferred: \(deferredSessions.count))")
            cleanup()
            return
        }
        
        // Persist session and all buffered data to SwiftData
        persistSession(session, snapshots: snapshotBuffer, syncEvents: syncEventBuffer, callsignEvents: callsignEventBuffer)
        
        appLog("ReceptionLogger: session saved, frames=\(session.totalModemFrames) syncRatio=\(String(format: "%.1f%%", session.syncRatio * 100))")
        cleanup()
    }
    
    // MARK: - Data Recording
    
    /// Record a signal snapshot. Called once per modem frame (~8.3 Hz) during SYNC.
    func recordSnapshot(_ snapshot: SignalSnapshot) {
        snapshot.session = currentSession
        snapshotBuffer.append(snapshot)
        
        // Detect sync state changes
        if snapshot.syncState != lastSyncState {
            let event = SyncEvent(
                timestamp: snapshot.timestamp,
                offsetMs: snapshot.offsetMs,
                fromState: lastSyncState,
                toState: snapshot.syncState,
                snrAtEvent: snapshot.snr,
                freqOffsetAtEvent: snapshot.freqOffset
            )
            event.session = currentSession
            syncEventBuffer.append(event)
            lastSyncState = snapshot.syncState
        }
        
        // Update session statistics
        currentSession?.totalModemFrames += 1
        if snapshot.syncState == 2 { // SYNC
            currentSession?.syncedFrames += 1
            if snapshot.snr > (currentSession?.peakSNR ?? -99) {
                currentSession?.peakSNR = snapshot.snr
            }
            snrSum += snapshot.snr
            snrCount += 1
        }
    }
    
    /// Record a callsign decode event with optional GPS location.
    func recordCallsign(_ callsign: String, snr: Float, modemFrame: Int,
                         latitude: Double? = nil, longitude: Double? = nil) {
        let normalizedCallsign = callsign
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .controlCharacters)
            .joined()
            .uppercased()
        guard !normalizedCallsign.isEmpty else { return }
        guard let session = currentSession else { return }
        
        let offsetMs = Int64(Date().timeIntervalSince(session.startTime) * 1000)
        let event = CallsignEvent(
            timestamp: Date(),
            offsetMs: offsetMs,
            callsign: normalizedCallsign,
            snrAtDecode: snr,
            modemFrame: modemFrame
        )
        event.latitude = latitude
        event.longitude = longitude
        event.session = session
        callsignEventBuffer.append(event)
        
        if !session.callsignsDecoded.contains(normalizedCallsign) {
            session.callsignsDecoded.append(normalizedCallsign)
        }
        
        appLog("ReceptionLogger: callsign decoded: \(normalizedCallsign) SNR=\(snr)")
    }
    
    // MARK: - Deferred Persistence
    
    /// Persist all deferred sessions to SwiftData at once.
    /// Called when the entire deferred decode finishes successfully.
    func flushDeferredSessions() {
        guard !deferredSessions.isEmpty else { return }
        let count = deferredSessions.count
        for entry in deferredSessions {
            persistSession(entry.session, snapshots: entry.snapshots,
                           syncEvents: entry.syncEvents, callsignEvents: entry.callsignEvents)
        }
        deferredSessions.removeAll()
        appLog("ReceptionLogger: flushed \(count) deferred sessions")
    }
    
    /// Discard all deferred sessions and their WAV files.
    /// Called when deferred decode is cancelled.
    func discardDeferredSessions() {
        for entry in deferredSessions {
            if let filename = entry.session.audioFilename {
                let url = WAVRecorder.recordingsDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: url)
            }
        }
        let count = deferredSessions.count
        deferredSessions.removeAll()
        if count > 0 {
            appLog("ReceptionLogger: discarded \(count) deferred sessions")
        }
    }
    
    // MARK: - Private
    
    private func persistSession(_ session: ReceptionSession, snapshots: [SignalSnapshot],
                                syncEvents: [SyncEvent], callsignEvents: [CallsignEvent]) {
        let saveWork = {
            self.modelContext.insert(session)
            for snap in snapshots {
                self.modelContext.insert(snap)
            }
            for event in syncEvents {
                self.modelContext.insert(event)
            }
            for event in callsignEvents {
                self.modelContext.insert(event)
            }
            try? self.modelContext.save()
        }

        if Thread.isMainThread {
            saveWork()
        } else {
            DispatchQueue.main.sync(execute: saveWork)
        }
    }
    
    private func discardSession() {
        // Delete WAV file if one was created
        if let filename = currentSession?.audioFilename {
            let url = WAVRecorder.recordingsDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        cleanup()
    }
    
    private func cleanup() {
        snapshotBuffer.removeAll(keepingCapacity: true)
        syncEventBuffer.removeAll(keepingCapacity: true)
        callsignEventBuffer.removeAll(keepingCapacity: true)
        currentSession = nil
    }
}
