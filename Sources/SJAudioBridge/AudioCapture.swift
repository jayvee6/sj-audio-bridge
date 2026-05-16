// B3+B4: SCStream system-audio capture → fixed-size Float32 mono PCM blocks.
//
// ScreenCaptureKit audio capture still requires an SCContentFilter with a
// display (the "display-filter trick") even though we only consume audio —
// we add only an `.audio` stream output and never handle screen frames, and
// shrink the video config to near-nothing so the GPU/encoder cost is trivial.
//
// `excludesCurrentProcessAudio = true` is a non-negotiable: the bridge must
// never capture its own output (feedback / privacy).
//
// B4 deliverable: downmix to mono and chunk into fixed `blockSize` Float32
// blocks — this is the exact payload the B6 WebSocket frames will ship. RMS
// is computed from the same mono blocks so the menubar stays a live
// correctness handle.

import CoreMedia
import Foundation
import ScreenCaptureKit

/// Owns the SCStream. Runs off the main actor; emits mono PCM blocks + RMS
/// via Sendable callbacks (caller hops to MainActor for UI).
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

    /// Output sample rate (we pin SCStreamConfiguration to this).
    static let sampleRate = 48_000

    private let queue = DispatchQueue(label: "dev.studiojoe.sjaudiobridge.audio")
    private var stream: SCStream?
    private let blockSize: Int
    private let onBlock: @Sendable ([Float]) -> Void
    private let onLevel: @Sendable (Float) -> Void

    // Mono accumulator → emitted in exact blockSize chunks.
    private var monoAccum: [Float] = []

    // RMS throttle over emitted mono samples (~0.5 s @ 48 kHz).
    private var accSquares: Double = 0
    private var accCount: Int = 0
    private let accThreshold = 24_000

    /// - Parameters:
    ///   - blockSize: mono samples per emitted block (default 1024 ≈ 21 ms).
    ///   - onBlock: receives an owned copy of exactly `blockSize` mono Float32.
    ///   - onLevel: RMS of recent mono audio, for the menubar readout.
    init(
        blockSize: Int = 1024,
        onBlock: @escaping @Sendable ([Float]) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        self.blockSize = blockSize
        self.onBlock = onBlock
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
        config.sampleRate = Self.sampleRate
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
        monoAccum.removeAll(keepingCapacity: false)
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }

        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                let buffers = Array(abl)
                guard let first = buffers.first, let firstData = first.mData else { return }

                if buffers.count >= 2 {
                    // Non-interleaved (planar): one Float32 buffer per channel.
                    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    let planes = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
                    let ch = Float(planes.count)
                    for f in 0..<frames {
                        var s: Float = 0
                        for p in planes { s += p[f] }
                        appendMono(s / ch)
                    }
                } else if first.mNumberChannels > 1 {
                    // Interleaved: single buffer, mNumberChannels samples/frame.
                    let ch = Int(first.mNumberChannels)
                    let total = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    let p = firstData.assumingMemoryBound(to: Float.self)
                    var i = 0
                    while i + ch <= total {
                        var s: Float = 0
                        for c in 0..<ch { s += p[i + c] }
                        appendMono(s / Float(ch))
                        i += ch
                    }
                } else {
                    // Already mono.
                    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    let p = firstData.assumingMemoryBound(to: Float.self)
                    for f in 0..<frames { appendMono(p[f]) }
                }
            }
        } catch {
            return
        }
    }

    /// Append one mono sample; flush a block + update RMS every `blockSize`.
    private func appendMono(_ v: Float) {
        monoAccum.append(v)
        accSquares += Double(v) * Double(v)
        accCount += 1

        if monoAccum.count >= blockSize {
            let block = Array(monoAccum.prefix(blockSize))
            monoAccum.removeFirst(blockSize)
            onBlock(block)
        }
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
