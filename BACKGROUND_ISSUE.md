# iOS Background Execution Issue

## Problem Summary

When the user switches to another app or locks the screen while RX is running, iOS terminates (kills) the app within seconds. The app should continue receiving and decoding RADE audio in the background.

## App Architecture

RADE Decode is an iOS ham radio digital voice receiver. It uses:

- **AVAudioEngine** with an input tap to capture microphone audio from a radio receiver
- **AVAudioSourceNode** connected to the output to play decoded speech
- **RADE modem** (C library via bridging header) for signal processing on a background `DispatchQueue`
- **CoreLocation** for background keep-alive and GPS logging
- **Live Activity** to show sync/SNR status on the lock screen

### Audio Pipeline

```
Microphone → inputNode.installTap() → processRXInput()
    → stereo-to-mono downmix → sample rate conversion (48kHz → 8kHz)
    → RADE modem (rx_process) → decoded 16kHz speech
    → AudioRingBuffer → AVAudioSourceNode render callback → speaker
```

### Background Modes (Info.plist)

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>location</string>
</array>
```

### Entitlements

- `com.apple.security.application-groups` (for widget data sharing)
- No `com.apple.developer.background-modes` entitlement (relies on Info.plist)

## Current Background Strategy

When the app enters background (`UIApplication.didEnterBackgroundNotification`), `TransceiverViewModel.enterBackground()` is called:

1. Disable FFT/waterfall computation (save CPU)
2. Stop UI update timer (no SwiftUI updates needed)
3. Call `audioManager.beginBackgroundTask()` — requests ~30s extra time
4. Call `audioManager.setBackgroundAudioMode(true)` — switches audio mode

### Audio Mode Switch (`setBackgroundAudioMode`)

The app uses `.measurement` mode in the foreground for raw, unprocessed audio (ideal for modem decoding). When entering background, it switches to `.default` mode because `.measurement` may not be recognized by iOS as "background-worthy" audio.

The full sequence:
```swift
// Step 1: Stop engine, remove input tap
inputNode.removeTap(onBus: 0)
audioEngine.stop()

// Step 2: Deactivate session (REQUIRED for mode change to take effect)
try session.setActive(false)

// Step 3: Set new category/mode
try session.setCategory(.playAndRecord, mode: .default,
                        options: [.allowBluetooth, .defaultToSpeaker])

// Step 4: Reactivate session
try session.setActive(true)

// Step 5: Restart engine with fresh tap
try audioEngine.start()
try inputNode.setVoiceProcessingEnabled(false)  // prevent echo cancellation
let inputFormat = inputNode.outputFormat(forBus: 0)
// Rebuild converter for potentially changed format
inputNode.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { ... }
```

### Location Keep-Alive

`LocationTracker` always starts `CLLocationManager.startUpdatingLocation()` when RX begins (regardless of GPS logging preference), with `allowsBackgroundLocationUpdates = true`. This should provide an additional background execution signal to iOS.

## Attempts Made

### Attempt 1: `.measurement` mode + location only
- Keep `.measurement` mode in background, rely on location updates
- **Result**: App killed within seconds

### Attempt 2: Switch to `.default` mode (full engine restart, NO tap reinstall)
- Stop engine → deactivate → switch to `.default` → reactivate → start engine
- Did NOT reinstall the input tap after engine restart
- **Result**: App stayed alive! But NOT decoding (input tap format mismatch after mode switch)

### Attempt 3: In-place mode switch (no engine stop)
- Only call `setCategory()` without stopping the engine
- **Result**: App killed — mode change doesn't take effect without `setActive(false)`

### Attempt 4: `.measurement` mode + always-start location (removed `guard isEnabled`)
- Ensure location always starts for keep-alive regardless of user preference
- **Result**: App killed — `.measurement` mode alone is insufficient

### Attempt 5: `.default` mode + tap reinstall, but no `setActive(false)`
- Full engine restart with tap reinstall, but skipped session deactivation
- **Result**: App killed — `setCategory` doesn't actually change mode without deactivation

### Attempt 6: Revert to `requestAlwaysAuthorization()` + `.measurement` + `reassertAudioSession()`
- Tried to use "provisional Always" authorization flow
- **Result**: App killed — device's existing authorization state wasn't reset

### Attempt 7: `.default` mode from the very start in `startRX()`
- Never use `.measurement` at all, start with `.default` mode so no switch is needed
- **Result**: App killed — `setCategory` on an already-active session may not take effect

### Attempt 8: Full deactivate/reactivate cycle + tap reinstall (current code)
- Complete sequence: stop engine → `setActive(false)` → `setCategory(.default)` → `setActive(true)` → start engine → disable voice processing → reinstall tap
- **Result**: App still killed

## Key Observation

**Attempt 2 is the ONLY approach that kept the app alive.** The difference:
- It did a full engine restart with `.default` mode
- It did NOT reinstall the input tap afterward
- The app survived in background but wasn't decoding (no input data flowing)

This suggests iOS keeps apps alive when:
1. The audio session is `.playAndRecord` with `.default` mode
2. The `AVAudioEngine` is running
3. An `AVAudioSourceNode` is connected and rendering (even silence)

But the input tap may be getting destroyed or invalidated during the engine restart cycle, and attempts to reinstall it might be causing the engine to be considered "not producing audio" by iOS.

## Hypotheses

### H1: The input tap installation is crashing or failing silently
When reinstalling the tap after mode switch, the `inputNode.outputFormat(forBus: 0)` may return a different format, and the tap installation might silently fail, leading iOS to determine the engine is not active.

### H2: `setActive(false)` during background transition triggers iOS suspension
Calling `setActive(false)` while already in background may signal to iOS that the app is done with audio, triggering immediate termination before `setActive(true)` can be called.

### H3: The mode switch is unnecessary — the real issue is something else
Perhaps `.measurement` mode works fine for background audio, and the actual problem is:
- Location authorization not being "Always" (only "When In Use" → iOS kills after ~10s)
- The `beginBackgroundTask` expiry handler calling `endBackgroundTask` too early
- The `AVAudioSourceNode` not producing enough audio frames

### H4: Race condition in background transition
The `didEnterBackgroundNotification` arrives too late — iOS has already started suspending the app, and the engine restart sequence can't complete in time.

### H5: Xcode debugger detachment misinterpreted as kill
When running from Xcode, the debugger detaches when the app enters background, showing signal 9 (SIGKILL). The app might actually be running fine — need to test without Xcode attached.

## Debug Strategy (In Progress)

Added local notifications to verify if the app is actually running in background:

1. **"RADE Background" notification** — sent when `setBackgroundAudioMode(true)` completes, confirming the mode switch happened
2. **"RADE Sync" notification** — sent when RADE sync is gained while in background, confirming audio is being processed

### How to test:
1. Install on device, grant notification permission
2. Start RX with a signal source
3. Switch to home screen (don't use Xcode Run — launch from home screen)
4. Wait for notifications:
   - If "RADE Background" appears → mode switch completed, app is alive
   - If "RADE Sync" appears → audio is being decoded in background (problem solved)
   - If neither appears → app is killed before mode switch completes (H2 or H4)

## Possible Solutions to Try

### S1: Don't switch modes at all — keep `.measurement` mode
Remove `setBackgroundAudioMode()` entirely. Only rely on:
- `UIBackgroundModes: [audio, location]`
- `AVAudioSourceNode` continuously rendering (even silence)
- Location updates running
- Test WITHOUT Xcode attached to rule out H5

### S2: Pre-emptive mode switch — use `.default` from `startRX()`
Start with `.default` mode always. Accept slightly degraded audio quality from echo cancellation (mitigated by `setVoiceProcessingEnabled(false)`).

### S3: Don't deactivate session — just restart engine
```swift
inputNode.removeTap(onBus: 0)
audioEngine.stop()
// Skip setActive(false) — the session stays active
try session.setCategory(.playAndRecord, mode: .default, options: [...])
try audioEngine.start()
// Reinstall tap
```
This was partially tried (attempt 5) but may have failed for other reasons.

### S4: Separate the output node from the mode switch
Keep the `AVAudioSourceNode` running (it produces silence/decoded speech). Only restart the input side. This requires restructuring the audio graph.

### S5: Use `BGProcessingTaskRequest` as additional keep-alive
Register a background processing task that periodically wakes the app. This is a fallback, not a primary solution.

### S6: Play silence explicitly through AVAudioPlayer
Some apps use a silent audio file on loop with `AVAudioPlayer` as a guaranteed background audio keep-alive, separate from the `AVAudioEngine` pipeline.

## Environment

- iOS 18.x (targeting iOS 18.0+)
- Xcode 16.x
- Device: iPhone (specific model unknown)
- Audio: `.playAndRecord` category, microphone input from radio receiver
- Location: "When In Use" or "Always" authorization (exact state uncertain)

## Files Involved

| File | Role |
|------|------|
| `FreeDV/Audio/AudioManager.swift` | Audio engine, mode switching, background audio |
| `FreeDV/ViewModels/TransceiverViewModel.swift` | Background/foreground transitions |
| `FreeDV/Location/LocationTracker.swift` | Location-based keep-alive |
| `FreeDV/App/FreeDVApp.swift` | Scene phase monitoring |
| `FreeDV/Info.plist` | Background modes declaration |
| `FreeDV/FreeDV.entitlements` | App capabilities |
