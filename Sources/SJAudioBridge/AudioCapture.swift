// B3: SCStream system-audio capture + live RMS.
//
// ScreenCaptureKit audio capture still requires an SCContentFilter with a
// display (the "display-filter trick") even though we only consume audio —
// we add only an `.audio` stream output and never handle screen frames, and
// shrink the video config to near-nothing so the GPU/encoder cost is trivial.
//
// `excludesCurrentProcessAudio = true` is a non-negotiable: the bridge must
// never capture its own output (feedback / privacy).
//
// B3 only computes RMS to prove real signal flows. B4 turns the same
// CMSampleBuffer path into Float32 mono PCM blocks for the WebSocket.

import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns the SCStream. Runs off the main actor; emits RMS levels via a
/// Sendable callback (caller hops to MainActor for UI).
final class AudioCapture: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    enum CaptureError: Error, CustomStringConvertible {
        case noDisplay
        case start(String)
        var description: String {
            switch self {
            case .noDisplay: return "No capturable display available"
            case let .start(m): return "SCStream start failed: \(m)"
            }
        }
    }

    private let queue = DispatchQueue(label: "dev.studiojoe.sjaudiobridge.audio")
    private var stream: SCStream?
    private let onLevel: @Sendable (Float) -> Void

    // RMS log throttle: accumulate ~0.5 s of audio before emitting one level.
    private var accSquares: Double = 0
    private var accCount: Int = 0
    private let accThreshold = 24_000  // ~0.5 s @ 48 kHz

    init(onLevel: @escaping @Sendable (Float) -> Void) {
        self.onLevel = onLevel
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Minimize the mandatory video path — we never read screen frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.start(String(describing: error))
        }
        self.stream = stream
    }

    func stop() async {
        guard let s = stream else { return }
        try? await s.stopCapture()
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }

        // SCK delivers 32-bit float PCM. Sum squares across every channel
        // buffer — exact channel layout is irrelevant for an RMS check.
        var sumSq: Double = 0
        var n = 0
        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                for buffer in abl {
                    guard let data = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<count {
                        let v = Double(samples[i])
                        sumSq += v * v
                    }
                    n += count
                }
            }
        } catch {
            return
        }
        guard n > 0 else { return }

        accSquares += sumSq
        accCount += n
        if accCount >= accThreshold {
            let rms = Float((accSquares / Double(accCount)).squareRoot())
            accSquares = 0
            accCount = 0
            onLevel(rms)
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(
            Data("[B3] stream stopped with error: \(error)\n".utf8)
        )
    }
}
