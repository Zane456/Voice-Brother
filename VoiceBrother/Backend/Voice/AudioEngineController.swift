import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Owns the `AVAudioEngine` capture lifecycle for voice recording: cold start /
/// reuse, the input tap, health-driven recovery, keep-alive teardown, and
/// input-device transport detection.
///
/// Recording-lifecycle state that the key-event handlers own (isRecording /
/// isCapturingTail / currentSessionID / asrEngine / keyboardListener) stays on
/// `VoiceService`; this controller reads it through a weak back-reference so the
/// tap/observer see exactly the same values as before the split.
@MainActor
final class AudioEngineController {

    private let chunkStore: VoiceAudioChunkStore
    private weak var voice: VoiceService?

    init(chunkStore: VoiceAudioChunkStore, voice: VoiceService) {
        self.chunkStore = chunkStore
        self.voice = voice
    }

    var audioEngine: AVAudioEngine?

    /// Diagnostic: count of audio tap callbacks received during current recording.
    /// Incremented from the CoreAudio IO thread (tap callback) and read/reset
    /// from the main actor (health-check timer), so all access goes through a
    /// lock — without it the `+= 1` read-modify-write races the main-actor reset
    /// and the "mic occupied" health check can observe a torn/stale value.
    private let tapFireCountLock = NSLock()
    private var _tapFireCount: Int = 0
    var tapFireCount: Int {
        get { tapFireCountLock.withLock { _tapFireCount } }
        set { tapFireCountLock.withLock { _tapFireCount = newValue } }
    }
    /// Atomic increment for the tap callback — the computed-property setter would
    /// take the lock twice (get then set), reopening the race.
    private func incrementTapFireCount() {
        tapFireCountLock.withLock { _tapFireCount += 1 }
    }

    /// Per-recording flag so the fast-recovery rebuild only runs once.
    var audioRecoveryAttempted = false

    /// Observer for `AVAudioEngineConfigurationChange`. Fires when the underlying
    /// audio device's config changes — typically when another app (WeChat, Zoom,
    /// etc.) ends a call and the system flips the input device back to its default
    /// sample rate. AVAudioEngine stops itself when this happens; we rebuild so
    /// the user's in-progress recording survives the transition.
    private var audioConfigChangeObserver: NSObjectProtocol?

    /// How long the audio health check waits before declaring "no buffers received,
    /// mic must be occupied". Bluetooth needs much more slack to allow the SCO link
    /// to finish warming up.
    var audioHealthCheckTimeout: TimeInterval {
        Self.isCurrentInputBluetooth() ? 4.0 : 1.2
    }

    /// How long to keep the audio engine running after a recording ends. For Bluetooth
    /// we want a generous window so back-to-back recordings reuse the already-warm
    /// SCO link instead of paying the warm-up cost again. For built-in mics this just
    /// reduces engine setup overhead. Set to 0 to disable.
    var keepAliveAfterRecording: TimeInterval {
        // Bluetooth bumped from 8s → 300s (5 min) to mirror how Doubao input method
        // feels: once the SCO link is up, every press for the next 5 minutes is
        // instant. Trade-off is AirPods music quality stays degraded (mono HFP) and
        // a slight battery cost while warm. Same approach used by macos-mic-keepwarm
        // and other push-to-talk tools. Built-in mic keep-alive stays at 3s — built-in
        // has no SCO cost so a long window has no benefit.
        Self.isCurrentInputBluetooth() ? 300.0 : 3.0
    }

    /// Pre-warm duration. Bluetooth needs longer to bring the SCO link up cleanly.
    private var prewarmDuration: TimeInterval {
        Self.isCurrentInputBluetooth() ? 1.5 : 0.5
    }

    /// Timer that delays actually shutting down the audio engine after a recording.
    /// Lets back-to-back recordings reuse the warm Bluetooth link.
    var engineKeepAliveTimer: Timer?

    /// When true, the audio engine is currently running in "keep-alive" mode —
    /// no recording is active, but the engine is held open so the next press can
    /// start instantly. Buffers received during this window are discarded.
    var engineWarmKept = false

    /// Per-recording flag set the first time the audio tap delivers a non-silent
    /// buffer. Used to discard the leading all-zero buffers that AirPods routinely
    /// emit during the SCO link warm-up — without this, the user's first 0.5–1.5s
    /// of speech ends up indistinguishable from silence and gets eaten by the
    /// silence-hallucination filter.
    var hasReceivedRealAudio = false

    /// Energy threshold (RMS on the raw buffer) below which we treat the buffer
    /// as "still warming up" and don't yet flip `hasReceivedRealAudio`. Tuned low
    /// (0.001) so it ONLY rejects the truly-zero buffers AirPods emits during
    /// SCO link establishment — production logs show those as RMS = 0.0 exactly.
    /// Anything above this — including very quiet whispers and ambient room
    /// noise — passes through, so we never chop the leading characters of
    /// soft-spoken input.
    private let leadingSilenceRMSThreshold: Float = 0.001

    /// Running peak used to drive a streaming-AGC view of the waveform. Mirrors
    /// the batch AGC in `transcribeAndInject` (which scales the whole utterance
    /// by `min(0.6 / peak, 40)`) so the bars reflect the level ASR will actually
    /// receive — a built-in mic gets pulled up, AirPods stay natural, no
    /// per-device tuning. Decays slowly so a transient pop can't suppress the
    /// rest of the recording.
    var streamingPeak: Float = 0

    // MARK: - Audio Engine

    /// Pre-warm audio hardware by briefly starting and stopping the engine.
    /// This ensures the first real recording has full audio levels instead of
    /// near-zero samples. Bluetooth gets a longer warm-up because the SCO link
    /// can take >1s to stabilize on AirPods specifically.
    func prewarmAudioEngine() {
        // A meeting recording owns the microphone. Do not keep VoiceService's
        // background warm-up tap alive while the meeting mic engine is active.
        guard voice?.keyboardListenerRef?.isMeetingActive != true else {
            debugLog("Pre-warm skipped — meeting recording owns the microphone")
            return
        }
        let isBluetooth = Self.isCurrentInputBluetooth()
        let warmDuration = prewarmDuration
        debugLog("Pre-warming audio engine (\(isBluetooth ? "Bluetooth" : "wired/built-in"), duration=\(warmDuration)s)")
        Task { @MainActor in
            do {
                let engine = AVAudioEngine()

                // Same off-main HAL handling as startAudioEngine — pre-warm must
                // never freeze the UI either (it runs at launch and after each
                // keep-alive expiry).
                let format: AVAudioFormat = await Task.detached(priority: .userInitiated) {
                    engine.inputNode.outputFormat(forBus: 0)
                }.value
                guard format.sampleRate > 0 else { return }

                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
                try await Task.detached(priority: .userInitiated) { try engine.start() }.value

                DispatchQueue.main.asyncAfter(deadline: .now() + warmDuration) {
                    // Stop before removeTap — see stopAudioEngineImmediately().
                    engine.stop()
                    engine.inputNode.removeTap(onBus: 0)
                }
            } catch {
                debugWarn("Audio pre-warm failed (non-fatal): \(error)")
            }
        }
    }

    /// Cold-starts (or reuses) the capture engine. The CoreAudio HAL queries it
    /// issues — the first `inputNode` access and `engine.start()` — can block on
    /// a synchronous `mach_msg` to coreaudiod for tens of seconds when the audio
    /// daemon is busy. Those two calls run on a detached task so the main actor
    /// stays responsive while the device/daemon settles; everything else stays
    /// on the main actor so the (unchanged) tap closure keeps its isolation.
    func startAudioEngine() async throws {
        // Engine reuse path: if a previous recording's keep-alive timer is still
        // holding the engine open (warm SCO link with AirPods, for example), reuse
        // it instead of paying the cold-start cost again.
        if let existing = audioEngine, existing.isRunning {
            engineKeepAliveTimer?.invalidate()
            engineKeepAliveTimer = nil
            engineWarmKept = false
            hasReceivedRealAudio = false
            debugLog("Reusing warm audio engine (keep-alive hit) — skipping cold start")
            return
        }

        // Belt-and-suspenders: if engineKeepAliveTimer fired but audioEngine is
        // somehow still around, tear it down before building a fresh one.
        stopAudioEngineImmediately()

        let engine = AVAudioEngine()

        // First `inputNode` access triggers AVAudioEngine's UpdateInputNode →
        // CoreAudio HAL GetHWFormat, a synchronous mach_msg to coreaudiod. Run
        // it off the main thread: a slow/wedged coreaudiod then merely delays
        // the recording instead of freezing the whole UI for tens of seconds.
        let format: AVAudioFormat = await Task.detached(priority: .userInitiated) {
            engine.inputNode.outputFormat(forBus: 0)
        }.value
        let inputNode = engine.inputNode
        debugLog("Audio format: sampleRate=\(format.sampleRate), channels=\(format.channelCount), bits=\(format.streamDescription.pointee.mBitsPerChannel), bluetooth=\(Self.isCurrentInputBluetooth())")

        // Validate format — on macOS cold start, sampleRate can be 0
        guard format.sampleRate > 0, format.channelCount > 0 else {
            debugLog("Invalid audio format! sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
            throw NSError(domain: "VoiceService", code: -1, userInfo: [NSLocalizedDescriptionKey: "麦克风格式无效 (sampleRate=\(format.sampleRate))"])
        }

        // We need 16kHz mono Float32 for the ASR model
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        // 某些场景下系统会把输入切到 VPIO 多通道模式（如微信通话，本机 9 ch），
        // 这种格式没有标准 channel layout，AVAudioConverter 无法把它降混成单声道
        // （会输出全 0）。所以转换器只负责采样率转换：源格式固定为「单声道 + 设备
        // 采样率」，降混由 tap 里自己取 channel 0（普通模式下 ch0 即麦克风信号）。
        let monoSourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: monoSourceFormat, to: targetFormat) else {
            debugLog("Failed to create audio converter from \(monoSourceFormat) to \(targetFormat)")
            throw NSError(domain: "VoiceService", code: -2, userInfo: [NSLocalizedDescriptionKey: "音频格式转换器创建失败"])
        }

        // Capture targetFormat and converter for the tap closure
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.incrementTapFireCount()
            guard self.voice?.isRecording ?? false else { return }

            // Compute RMS audio level from raw buffer for waveform animation + leading-silence detection
            var rawRMS: Float = 0
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0
                var bufferPeak: Float = 0
                for i in 0..<frameLength {
                    let s = channelData[i]
                    sum += s * s
                    let a = abs(s)
                    if a > bufferPeak { bufferPeak = a }
                }
                rawRMS = sqrtf(sum / Float(max(frameLength, 1)))
                // Streaming AGC — same shape as the batch AGC in
                // transcribeAndInject (gain = min(0.6 / peak, 40)). Decay factor
                // 0.995 per buffer ≈ 3 s half-life at typical buffer rates, so a
                // transient pop doesn't lock the gain low for the rest of the
                // utterance. The waveform now shows what ASR will actually hear.
                self.streamingPeak = max(bufferPeak, self.streamingPeak * 0.995)
                let gain: Float = self.streamingPeak > 0
                    ? min(Float(0.6) / self.streamingPeak, Float(40))
                    : 1
                let gainedRMS = rawRMS * gain
                let dB = 20 * log10(max(gainedRMS, 1e-6))
                // Post-AGC window: speech RMS sits around -20 ~ -10 dBFS once the
                // gain converges (peak pinned to 0.6 ≈ -4.4 dBFS, crest factor
                // ~12-15 dB). Mapping [-50, -10] → [0, 1] keeps quiet gaps low
                // and active speech filling most of the bar.
                let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
                // Freeze the waveform the moment the user releases the key,
                // even though we keep capturing audio for the tail window.
                // The user's "I'm done" gesture should produce immediate
                // visual feedback regardless of how long ASR takes.
                if !(self.voice?.isCapturingTail ?? false) {
                    DispatchQueue.main.async {
                        self.voice?.overlay.updateAudioLevel(normalized)
                    }
                }
            }

            // Bluetooth (AirPods) warm-up workaround: SCO link routinely emits
            // 0.5–1.5s of all-zero buffers before real audio shows up. Skip those
            // — once we've heard real audio, every subsequent buffer (including
            // mid-sentence pauses) is appended normally so we don't truncate
            // silences inside the user's speech.
            if !self.hasReceivedRealAudio {
                if rawRMS < self.leadingSilenceRMSThreshold {
                    return
                }
                self.hasReceivedRealAudio = true
            }

            // VPIO 给的是多通道 buffer（各通道内容完全相同），先手动取 channel 0
            // 拼成单声道 buffer，再交给转换器做 48k→16k 采样率转换。
            guard buffer.frameLength > 0, let srcChannel = buffer.floatChannelData?[0] else { return }
            guard let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoSourceFormat,
                frameCapacity: buffer.frameLength
            ) else {
                DebugLog.write("[VoiceService] Audio tap: FAILED to allocate mono buffer")
                return
            }
            monoBuffer.frameLength = buffer.frameLength
            memcpy(monoBuffer.floatChannelData![0], srcChannel,
                   Int(buffer.frameLength) * MemoryLayout<Float>.size)

            // Convert to 16kHz mono Float32
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / format.sampleRate)
            // Skip empty buffers — allocating with capacity 1 would yield an
            // unusable buffer whose floatChannelData pointer can't be safely read.
            guard frameCount > 0 else { return }
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else {
                DebugLog.write("[VoiceService] Audio tap: FAILED to allocate converted buffer")
                return
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return monoBuffer
            }

            guard status != .error else {
                DebugLog.write("[VoiceService] Audio tap: conversion error: \(error?.localizedDescription ?? "unknown")")
                return
            }

            // Extract float samples as Data
            if let channelData = convertedBuffer.floatChannelData {
                let floatCount = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: floatCount * MemoryLayout<Float>.size)
                self.chunkStore.appendAudioChunk(data)

                // Stream audio to cloud ASR in real-time
                if let volcEngine = self.voice?.asrEngine as? VolcanoASREngine, volcEngine.isStreaming {
                    let samples = Array(UnsafeBufferPointer(start: channelData[0], count: floatCount))
                    let pcm = volcEngine.floatToPCM16(samples)
                    volcEngine.feedAudio(pcm)
                }
            } else {
                DebugLog.write("[VoiceService] Audio tap: no channel data in converted buffer (frameLength=\(convertedBuffer.frameLength))")
            }
        }

        // engine.start() spins up the CoreAudio IO thread — also a synchronous
        // HAL round-trip that can stall on a busy coreaudiod. Off the main
        // thread for the same reason as the inputNode query above.
        try await Task.detached(priority: .userInitiated) { try engine.start() }.value
        self.audioEngine = engine

        // Listen for configuration changes (e.g. WeChat ends a call → device flips
        // back to default sample rate). AVAudioEngine stops itself on this event,
        // so we trigger a rebuild to keep the in-progress recording alive.
        if let existing = audioConfigChangeObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        audioConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.voice?.isRecording ?? false else { return }
                await self.attemptAudioEngineRecovery(reason: "AVAudioEngineConfigurationChange (device format changed mid-recording)")
            }
        }
    }

    /// Tear down the current engine and rebuild it once. Used both as a fast retry
    /// when the first engine failed to deliver any samples (mic was occupied at
    /// startup) and as a recovery from `AVAudioEngineConfigurationChange` (another
    /// app released the device mid-recording, system flipped formats).
    func attemptAudioEngineRecovery(reason: String) async {
        guard voice?.isRecording ?? false else { return }
        ASRLogger.shared.event(.audioEngineRecoveryAttempt, sessionID: voice?.currentSessionID,
                               props: ["reason": reason,
                                       "alreadyAttempted": audioRecoveryAttempted])
        guard !audioRecoveryAttempted else {
            debugLog("Audio engine recovery skipped — already attempted this session (\(reason))")
            return
        }
        audioRecoveryAttempted = true
        debugLog("Audio engine recovery: rebuilding engine — \(reason)")
        stopAudioEngineImmediately()
        do {
            try await startAudioEngine()
            // The recording may have ended (key release / ESC / meeting) during
            // the rebuild's cold-start await — don't leave a resurrected engine.
            guard voice?.isRecording ?? false else {
                debugLog("Audio engine recovery: recording ended during rebuild — releasing engine")
                stopAudioEngineImmediately()
                return
            }
            debugLog("Audio engine recovery: rebuild succeeded")
        } catch {
            debugError("Audio engine recovery: rebuild FAILED: \(error) — health check will abort if still no audio")
        }
    }

    /// Default stop path: respects `keepAliveAfterRecording`. For Bluetooth (AirPods)
    /// this keeps the engine running for several seconds so the next press reuses
    /// the warm SCO link without paying another 1–2s warm-up cost. For built-in
    /// mics the keep-alive is shorter but still saves cold-start overhead on rapid
    /// successive recordings. Failure / cancellation paths should call
    /// `stopAudioEngineImmediately()` instead — we don't want to hold the mic open
    /// after an error.
    func stopAudioEngine() {
        let keepAlive = keepAliveAfterRecording
        guard keepAlive > 0, let engine = audioEngine, engine.isRunning else {
            stopAudioEngineImmediately()
            return
        }

        engineWarmKept = true
        debugLog("Engine kept warm for \(keepAlive)s (next recording will reuse warm link)")
        engineKeepAliveTimer?.invalidate()
        engineKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: keepAlive, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only actually stop if no recording started in the meantime — a fresh
                // press would have flipped engineWarmKept back to false.
                guard self.engineWarmKept else { return }
                self.debugLog("Engine keep-alive expired, stopping audio engine")
                self.stopAudioEngineImmediately()
            }
        }
    }

    /// Hard stop. Tears down the engine right away — used for errors, cancellation,
    /// and service shutdown.
    func stopAudioEngineImmediately() {
        engineKeepAliveTimer?.invalidate()
        engineKeepAliveTimer = nil
        engineWarmKept = false
        if let observer = audioConfigChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            audioConfigChangeObserver = nil
        }
        if let engine = audioEngine {
            // Order matters: stop the engine BEFORE removing the tap.
            // `stop()` quiesces the CoreAudio IO thread; only then is it safe
            // for `removeTap` to release the tap closure (and the
            // AVAudioConverter it captures). The reverse order races the IO
            // thread — it can dereference the just-freed converter and jump to
            // a null callback (EXC_BAD_ACCESS / SIGSEGV on the audio thread).
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    // MARK: - Input Device Selection

    /// Returns `true` if the current system default input device is a Bluetooth mic
    /// (AirPods, generic BT headset, etc.). When true, downstream timing parameters
    /// — prewarm length, health-check window, leading-silence skip — get widened to
    /// accommodate the slow A2DP→HFP/SCO switch.
    ///
    /// The transport type is read fresh each call (not cached) because the user can
    /// connect/disconnect AirPods mid-session and we want to react.
    nonisolated static func isCurrentInputBluetooth() -> Bool {
        guard let transport = currentDefaultInputTransportType() else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Look up the system default input device and return its CoreAudio transport type.
    /// Returns nil if no default input is set (rare — usually only on freshly booted
    /// machines with no mic at all).
    nonisolated private static func currentDefaultInputTransportType() -> UInt32? {
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddr, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport
        ) == noErr else { return nil }
        return transport
    }

    /// Find the MacBook's built-in microphone and bind `engine`'s inputNode to it.
    /// Falls back silently if the built-in mic can't be located (e.g. headless Mac mini),
    /// in which case AVAudioEngine uses the system default — better than crashing.
    ///
    /// Why this exists: on macOS, when AirPods/any Bluetooth mic is the system
    /// default, AVAudioEngine's input path grabs it and switches the headset
    /// into HFP/SCO mode (16 kHz mono, phone-call audio). That link is unstable
    /// and frequently delivers all-zero buffers — which is what we observed in
    /// production logs (`tapFired=47, RMS=0.0`). Forcing built-in bypasses the
    /// problem entirely and keeps A2DP intact for music playback in headphones.
    ///
    /// NOTE: Currently unused — we now respect the user's chosen input device
    /// (including AirPods) and absorb the SCO-link cost via Bluetooth-aware
    /// timing. Kept around in case we want a "force built-in" toggle later.
    nonisolated private static func forceInputToBuiltInMic(engine: AVAudioEngine, debug: ((String) -> Void)?) {
        guard let deviceID = findBuiltInInputDeviceID() else {
            debug?("forceInputToBuiltInMic: no built-in input device found, using system default")
            return
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            debug?("forceInputToBuiltInMic: inputNode.audioUnit is nil")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            debug?("forceInputToBuiltInMic: bound to deviceID=\(deviceID)")
        } else {
            debug?("forceInputToBuiltInMic: AudioUnitSetProperty failed, status=\(status)")
        }
    }

    /// Enumerate CoreAudio devices and return the first one that has input
    /// streams and reports `kAudioDeviceTransportTypeBuiltIn`. On Apple Silicon
    /// Macs with only a built-in mic this is trivially the right answer; on
    /// Intel with multiple built-ins (rare) we take the first match.
    nonisolated private static func findBuiltInInputDeviceID() -> AudioDeviceID? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &devices
        ) == noErr else { return nil }

        for deviceID in devices {
            // Must expose input streams — rules out output-only devices.
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            // Must be transport type "built-in".
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                deviceID, &transportAddr, 0, nil, &transportSize, &transport
            ) == noErr else { continue }

            if transport == kAudioDeviceTransportTypeBuiltIn {
                return deviceID
            }
        }
        return nil
    }

    // MARK: - Debug

    // Keep the `[VoiceService]` log prefix so existing log greps/monitors are unaffected.
    private func debugLog(_ message: String) {
        DebugLog.write("[VoiceService] \(message)")
    }

    private func debugWarn(_ message: String) {
        DebugLog.warn("[VoiceService] \(message)")
    }

    private func debugError(_ message: String) {
        DebugLog.error("[VoiceService] \(message)")
    }
}
