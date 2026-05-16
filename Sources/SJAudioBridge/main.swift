// SJAudioBridge — native macOS system-audio capture → localhost WebSocket
// for sj-audio's createNativeBridgeSource() web adapter.
//
// B1: LSUIElement menubar app skeleton. NSStatusItem with a status line and
// Quit. No capture yet — ScreenCaptureKit lands in B2/B3, the WS server in
// B5/B6, and the live Start/Stop + Copy-token UI in B7.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var capture: AudioCapture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "SJAudioBridge"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "SJAudioBridge \(appVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        statusMenuItem = NSMenuItem(
            title: "Status: checking capture access…",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit SJAudioBridge",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // B2: probe Screen Recording access + enumerate shareable content.
        // The grant prompt appears here on first launch (signed build).
        ScreenCaptureAccess.request()
        Task { await self.refreshCaptureStatus() }
    }

    private func refreshCaptureStatus() async {
        let line: String
        do {
            let s = try await ShareableContent.summarize()
            line = "Capture OK — \(s.displayCount) display(s), "
                + "\(s.applicationCount) app(s)"
            FileHandle.standardError.write(Data(
                ("[B2] \(line); first: \(s.firstDisplayDescription ?? "none")\n").utf8
            ))
            statusMenuItem.title = "Status: \(line)"
            await startCapture()
            return
        } catch {
            line = "No capture access — grant Screen Recording"
            FileHandle.standardError.write(Data(
                ("[B2] \(error)\n").utf8
            ))
        }
        statusMenuItem.title = "Status: \(line)"
    }

    private let blockMeter = BlockMeter()

    /// B4: start capture producing fixed-size mono PCM blocks. onBlock is
    /// where the B6 WebSocket will ship frames; for now we count blocks so
    /// the menubar shows dBFS + block-rate (1024 @ 48 kHz ≈ 46.9 blk/s) —
    /// a strong objective correctness signal for the mono-downmix path.
    private func startCapture() async {
        let meter = blockMeter
        let cap = AudioCapture(
            blockSize: 1024,
            onBlock: { block in
                // Audio queue. B5/B6: forward `block` to the WebSocket.
                meter.record(blockSamples: block.count)
            },
            onLevel: { [weak self] rms in
                let rmsD = Double(rms)
                let db = rmsD > 0 ? 20 * log10(rmsD) : -120
                let (blkPerSec, lastBlockSize) = meter.sampleAndReset()
                FileHandle.standardError.write(Data(
                    (String(
                        format: "[B4] RMS=%.5f (%.1f dBFS) %.1f blk/s size=%d sr=%d\n",
                        rmsD, db, blkPerSec, lastBlockSize, AudioCapture.sampleRate
                    )).utf8
                ))
                Task { @MainActor in
                    self?.statusMenuItem.title = String(
                        format: "Status: capturing — %.1f dBFS · %.0f blk/s",
                        db, blkPerSec
                    )
                }
            }
        )
        do {
            try await cap.start()
            capture = cap
            FileHandle.standardError.write(Data("[B4] SCStream capture started\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[B4] capture start failed: \(error)\n".utf8))
            statusMenuItem.title = "Status: capture start failed"
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// Lock-guarded block-rate meter. record() fires on the audio queue per
/// emitted PCM block; sampleAndReset() is read ~every 0.5 s from the same
/// queue (onLevel). NSLock keeps it correct under Swift 6 strict concurrency.
final class BlockMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastBlockSize = 0
    private var windowStart = Date()

    func record(blockSamples: Int) {
        lock.lock()
        count += 1
        lastBlockSize = blockSamples
        lock.unlock()
    }

    /// Returns (blocksPerSecond, lastBlockSize) and resets the window.
    func sampleAndReset() -> (Double, Int) {
        lock.lock()
        let now = Date()
        let elapsed = max(now.timeIntervalSince(windowStart), 0.001)
        let rate = Double(count) / elapsed
        let size = lastBlockSize
        count = 0
        windowStart = now
        lock.unlock()
        return (rate, size)
    }
}

// Top-level AppKit bring-up. `app.run()` never returns, so `delegate` stays
// retained for the process lifetime (NSApplication.delegate is weak).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // .accessory = menubar-only, no Dock icon (mirrors LSUIElement).
    app.setActivationPolicy(.accessory)
    app.run()
}
