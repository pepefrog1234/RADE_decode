# RADE Decode v1.2 — TestFlight Release Notes

## What's New

This release fixes four issues reported by field testers: the received SNR not appearing on FreeDV Reporter, HOLD TO TALK dropping out of transmit while held, spaces not working in the Status Message field, and reporter settings being hidden while reporting is off.

---

## Fixed Issues

### 1. FreeDV Reporter — received SNR was never uploaded

The SNR column for your station on qso.freedv.org stayed blank even while the app was synced and showing SNR on screen. The app only sent a reception report after a successful end-of-over callsign decode, which often never happened.

The app now reports the current SNR **every 10 seconds while synced** (same behavior as the desktop version), plus an immediate report whenever a callsign is decoded. Reports also use the live modem SNR instead of a value that could be stale after background operation.

### 2. HOLD TO TALK did not maintain transmit

Releasing PTT starts a ~1-second end-of-over tail before the radio is actually unkeyed. Pressing PTT again inside that window was silently ignored — and the pending unkey then dropped the radio back to RX **while the button was still held**. A brief touch loss while pressing hard (a rolling fingertip is enough) triggered the same chain, so holds could drop seemingly at random.

Now:
- Re-keying during the tail cancels the pending unkey and resumes the over seamlessly — the radio never unkeys under a held PTT.
- A 200 ms release debounce absorbs momentary touch losses without ending the over.
- Fixed a race where an extremely fast press-release could leave the radio stuck in transmit.

### 3. Status Message — spaces could not be typed

The right-aligned text field silently dropped trailing spaces as you typed. The field is now a left-aligned editor; spaces work normally, and pressing Return sends the updated message immediately.

### 4. Reporter settings hidden while reporting is off

Callsign, Grid Square, Frequency, and Status Message are now visible and editable while "Enable Reporting" is OFF, so everything can be prepared in advance. Connection status still appears only when reporting is enabled.

---

## What to Test

### 1. FreeDV Reporter SNR (Fix #1)

**Prerequisite:** Reporting enabled with callsign + grid square; any RADE signal to receive.

- [ ] Start RX and achieve sync on a signal
- [ ] Within ~10 s, your row on qso.freedv.org shows an SNR value
- [ ] SNR keeps refreshing (~every 10 s) during continuous reception
- [ ] After an end-of-over callsign decode, RX Call and SNR update immediately
- [ ] Losing and regaining sync produces a fresh report right after re-sync

### 2. HOLD TO TALK stability (Fix #2)

**Prerequisite:** IC-705 connected over WiFi, RX running.

- [ ] Hold PTT continuously for 10+ seconds — the radio stays keyed the whole time
- [ ] Press, release, and immediately press again (within ~1 s) — the radio must NOT unkey during the second hold
- [ ] While holding, deliberately roll/slide the fingertip — transmit continues uninterrupted
- [ ] Normal release still unkeys after the ~1.3 s tail, and the remote station still decodes the EOO callsign
- [ ] Console log shows "TX: re-key during stop drain" when the quick re-press path is exercised

### 3. Status Message (Fix #3)

- [ ] Type a message containing spaces (e.g. "QRV 40m JA1XXX") — spaces appear as typed
- [ ] Press Return — the message updates on qso.freedv.org immediately
- [ ] Leaving the Settings page also sends the latest message

### 4. Settings visibility (Fix #4)

- [ ] With "Enable Reporting" OFF, all reporter fields are visible and editable
- [ ] Turn reporting ON — the pre-entered values are used as-is
- [ ] With the IC-705 audio source selected, Frequency still shows as locked ("Synced from IC-705")

### 5. Regression check

- [ ] Normal RX, decode, and reception logging still work
- [ ] Background capture → foreground analysis still works
- [ ] Reporter connects only while RX is running, and disconnects on STOP

---

## Notes / Answers to Field Reports

- **Waterfall display:** the waterfall was intentionally replaced by the Band Activity list (lower CPU, and finding active frequencies is what the list does better). The spectrum display remains. This is by design, not a bug.
- **Microphone gain:** the hardware input gain is deliberately fixed to bypass iOS AGC, which would otherwise modulate the modem signal — adjustments made in Control Center are overridden by design. Use **Settings → RX Input Gain** to adjust the receive level instead.
- **IC-705 "No login reply" on Android:** that report concerns RADE_decode_Android and is not part of this iOS build.
- **Slow RX waveform recovery (~10 s) after transmit:** the IC-705 occasionally stops its audio stream after an over; the app detects this and restarts the stream automatically (worst case a few seconds). Reports with timestamps help us tune this further.

## How to Report Issues

Please include:
1. Steps to reproduce
2. Screenshots or screen recordings
3. Approximate time the issue occurred (to correlate with console logs)

## Build Info

Version: 1.2
Build: 7
Minimum iOS: 18.0
