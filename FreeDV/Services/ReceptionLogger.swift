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
    
    /// Minimum synced frames required to keep a session.
    /// At ~8 frames/sec, 4 frames ≈ 0.5 seconds — filters only very brief false syncs.
    private let minSyncedFrames = 4
    
    init(modelContainer: ModelContainer) {
        self.modelContext = ModelContext(modelContainer)
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
    
    func endSession() {
        guard let session = currentSession else { return }
        
        session.endTime = Date()
        
        // Calculate average SNR from synced frames
        if snrCount > 0 {
            session.avgSNR = snrSum / Float(snrCount)
        }
        
        // Discard session if too few synced frames (likely false sync)
        if session.syncedFrames < minSyncedFrames {
            appLog("ReceptionLogger: session discarded (syncedFrames=\(session.syncedFrames) < \(minSyncedFrames))")
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
        
        // Persist session and all buffered data to SwiftData
        modelContext.insert(session)
        for snap in snapshotBuffer {
            modelContext.insert(snap)
        }
        for event in syncEventBuffer {
            modelContext.insert(event)
        }
        for event in callsignEventBuffer {
            modelContext.insert(event)
        }
        try? modelContext.save()
        
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
        guard let session = currentSession else { return }
        
        let offsetMs = Int64(Date().timeIntervalSince(session.startTime) * 1000)
        let event = CallsignEvent(
            timestamp: Date(),
            offsetMs: offsetMs,
            callsign: callsign,
            snrAtDecode: snr,
            modemFrame: modemFrame
        )
        event.latitude = latitude
        event.longitude = longitude
        event.session = session
        callsignEventBuffer.append(event)
        
        if !session.callsignsDecoded.contains(callsign) {
            session.callsignsDecoded.append(callsign)
        }
        
        appLog("ReceptionLogger: callsign decoded: \(callsign) SNR=\(snr)")
    }
    
    // MARK: - Private
    
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
