import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Records the screen to a `.mov` file for the duration of a meeting.
///
/// Owns an `AVAssetWriter` with two inputs:
/// - video, fed by the `.screen` sample buffers of the meeting's `SCStream`
/// - audio (AAC), fed by the mixed mic + system samples that `MeetingService`
///   already produces for its WAV archive and ASR
///
/// Every operation is serialized on `outputQueue`, which is also the
/// `sampleHandlerQueue` registered for the `.screen` stream output. On any
/// failure the recorder sets `failed` and silently drops the rest — screen
/// recording must never break the meeting itself.
final class MeetingScreenRecorder: NSObject, @unchecked Sendable {

    /// Serial queue: SCStream `.screen` callbacks land here directly, and
    /// `start` / `appendAudio` / `finish` / `cancel` all hop onto it. Passed
    /// to `SCStream.addStreamOutput(_:type:sampleHandlerQueue:)` by the caller.
    let outputQueue = DispatchQueue(label: "com.voicebubble.screenrecorder")

    /// 16 kHz — the rate of the mixed audio `MeetingService` hands us.
    private static let audioSampleRate: Int32 = 16000

    private let outputURL: URL

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    /// PTS of the first complete video frame; the writer session starts here
    /// and audio timestamps are derived relative to it.
    private var firstVideoPTS: CMTime = .invalid
    /// True once `startSession` has been called (on the first complete frame).
    private var sessionStarted = false
    /// Set on any unrecoverable error — all further appends are dropped.
    private var failed = false
    /// Running count of audio sample frames appended, for deriving audio PTS.
    private var audioSampleCursor: Int64 = 0

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    // MARK: - Lifecycle

    /// Build and start the `AVAssetWriter`. `displaySize` is the pixel size of
    /// the video track (matches the `SCStreamConfiguration` width/height);
    /// `bitrate` is the H.264 average bitrate — the dominant factor in whether
    /// screen text looks sharp (resolution alone is not enough). Called before
    /// the stream output is registered, so the writer is ready by the time the
    /// first frame arrives.
    func start(displaySize: CGSize, bitrate: Int) {
        outputQueue.async {
            do {
                try? FileManager.default.removeItem(at: self.outputURL)
                let writer = try AVAssetWriter(outputURL: self.outputURL, fileType: .mov)

                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(displaySize.width),
                    AVVideoHeightKey: Int(displaySize.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoMaxKeyFrameIntervalKey: 48,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    ],
                ]
                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                videoInput.expectsMediaDataInRealTime = true

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Int(Self.audioSampleRate),
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 32000,
                ]
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true

                guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                    throw NSError(domain: "MeetingScreenRecorder", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "AVAssetWriter cannot add inputs"
                    ])
                }
                writer.add(videoInput)
                writer.add(audioInput)

                guard writer.startWriting() else {
                    throw writer.error ?? NSError(domain: "MeetingScreenRecorder", code: 2)
                }

                self.writer = writer
                self.videoInput = videoInput
                self.audioInput = audioInput
            } catch {
                print("[MeetingScreenRecorder] start failed: \(error). Screen recording disabled for this meeting.")
                self.failed = true
            }
        }
    }

    /// Finalize the `.mov`. Returns true only if a usable file was written.
    /// On failure (or if no video frame ever arrived) the partial file is
    /// deleted. Awaited by `MeetingService` during meeting finalization.
    @discardableResult
    func finish() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            outputQueue.async {
                guard let writer = self.writer, self.sessionStarted, !self.failed else {
                    self.writer?.cancelWriting()
                    try? FileManager.default.removeItem(at: self.outputURL)
                    continuation.resume(returning: false)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                writer.finishWriting {
                    let ok = writer.status == .completed
                    if !ok {
                        try? FileManager.default.removeItem(at: self.outputURL)
                    }
                    continuation.resume(returning: ok)
                }
            }
        }
    }

    /// Abort recording and delete any partial file. Used for empty meetings
    /// and error paths.
    func cancel() {
        outputQueue.async {
            self.failed = true
            if let writer = self.writer, writer.status == .writing {
                writer.cancelWriting()
            }
            try? FileManager.default.removeItem(at: self.outputURL)
        }
    }

    // MARK: - Audio

    /// Append a chunk of mixed mono 16 kHz float samples. Called from
    /// `MeetingService`'s recording loop. Dropped until the video session has
    /// started (so audio shares the video timeline).
    func appendAudio(_ samples: [Float]) {
        outputQueue.async {
            guard !self.failed, self.sessionStarted,
                  let audioInput = self.audioInput,
                  !samples.isEmpty else { return }
            guard let sampleBuffer = self.makeAudioSampleBuffer(samples) else { return }
            guard audioInput.isReadyForMoreMediaData else { return }
            if !audioInput.append(sampleBuffer) {
                print("[MeetingScreenRecorder] audio append failed: \(String(describing: self.writer?.error))")
                self.failed = true
            }
        }
    }

    /// Build an LPCM (float32 mono) `CMSampleBuffer` for the given samples.
    /// PTS is `firstVideoPTS + audioSampleCursor / 16000`; the cursor advances
    /// even if the buffer is later dropped, so timing never drifts.
    private func makeAudioSampleBuffer(_ samples: [Float]) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.audioSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else { return nil }

        let pts = CMTimeAdd(
            firstVideoPTS,
            CMTime(value: audioSampleCursor, timescale: Self.audioSampleRate)
        )
        audioSampleCursor += Int64(samples.count)

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }

        let copyOK = samples.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            ) == noErr
        }
        guard copyOK else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.audioSampleRate),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

// MARK: - SCStreamOutput (video frames)

extension MeetingScreenRecorder: @preconcurrency SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Runs on `outputQueue` (registered as the sampleHandlerQueue).
        guard type == .screen, !failed,
              let writer = writer, let videoInput = videoInput else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), isComplete(sampleBuffer) else { return }

        if !sessionStarted {
            firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: firstVideoPTS)
            sessionStarted = true
        }

        guard videoInput.isReadyForMoreMediaData else { return }
        if !videoInput.append(sampleBuffer) {
            print("[MeetingScreenRecorder] video append failed: \(String(describing: writer.error))")
            failed = true
        }
    }

    /// A `.screen` sample buffer is only safe to write when its frame status
    /// attachment is `.complete` (idle/blank frames carry no pixels).
    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = array.first,
              let raw = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
