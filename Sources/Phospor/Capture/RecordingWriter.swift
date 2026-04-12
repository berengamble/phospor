import Foundation
import AVFoundation
import CoreMedia

/// Thin wrapper around `AVAssetWriter` with a single H.264 video input.
/// Receives `CMSampleBuffer`s straight from the ScreenCaptureKit output queue.
final class RecordingWriter: @unchecked Sendable {
    let outputURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var sessionStarted = false
    private let lock = NSLock()

    init(outputURL: URL, width: Int, height: Int) throws {
        // Ensure parent dir exists.
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        self.outputURL = outputURL
        self.writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Reasonable bit-rate budget: ~8 bits per pixel * frames worth.
        let pixelCount = Double(width * height)
        let bitRate = Int(min(pixelCount * 8.0, 40_000_000)) // cap 40 Mbps

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: false
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        self.videoInput = input

        guard writer.canAdd(input) else {
            throw NSError(
                domain: "phospor.writer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter rejected video input"]
            )
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "phospor.writer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "startWriting() returned false"]
            )
        }
    }

    /// Append a single sample buffer. Safe to call from any thread.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        lock.lock()
        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        let ready = videoInput.isReadyForMoreMediaData
        lock.unlock()

        if ready {
            videoInput.append(sampleBuffer)
        }
    }

    /// Flush + finalize. Returns the output URL when finished.
    func finish() async -> URL {
        lock.lock()
        videoInput.markAsFinished()
        lock.unlock()
        await writer.finishWriting()
        return outputURL
    }
}
