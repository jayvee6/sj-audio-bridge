// SJAudioBridge — native macOS system-audio capture → localhost WebSocket
// for sj-audio's createNativeBridgeSource() web adapter.
//
// B7: full menubar UI — live status, WS endpoint, Copy Connection Token,
// Start/Stop Capture toggle, Quit. The WebSocket server runs for the app's
// lifetime (loopback + token-gated → harmless idle); Start/Stop toggles only
// the privacy-relevant ScreenCaptureKit capture (the macOS recording
// indicator appears/disappears with it).

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var capture: AudioCapture?
    private let wsServer = WSServer()
    private let blockMeter = BlockMeter()
    private var wsStarted = false
    private var capturing = false

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
            action: nil, keyEquivalent: ""
        )
        menu.addItem(statusMenuItem)

        let endpoint = NSMenuItem(
            title: "Endpoint: \(wsServer.endpointURL)",
            action: nil, keyEquivalent: ""
        )
        menu.addItem(endpoint)
        menu.addItem(.separator())

        let copyTok = NSMenuItem(
            title: "Copy Connection Token",
            action: #selector(copyToken), keyEquivalent: "c"
        )
        copyTok.target = self
        menu.addItem(copyTok)

        toggleItem = NSMenuItem(
            title: "Stop Capture",
            action: #selector(toggleCapture), keyEquivalent: ""
        )
        toggleItem.target = self
        toggleItem.isEnabled = false  // enabled once access is confirmed
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit SJAudioBridge",
            action: #selector(quit), keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        // WS server runs for the app lifetime — token-gated loopback, no
        // audio leaves without both a valid token AND active capture.
        startWSServerOnce()

        // B2: probe Screen Recording access (prompts on first launch).
        ScreenCaptureAccess.request()
        Task { await self.refreshCaptureStatus() }
    }

    private func startWSServerOnce() {
        guard !wsStarted else { return }
        do {
            try wsServer.start()
            wsStarted = true
            FileHandle.standardError.write(Data(
                "[B7] WS server up at \(wsServer.endpointURL)\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data("[B7] WS server failed: \(error)\n".utf8))
            statusMenuItem.title = "Status: WS server failed to start"
        }
    }

    private func refreshCaptureStatus() async {
        do {
            let s = try await ShareableContent.summarize()
            FileHandle.standardError.write(Data(
                ("[B7] Capture OK — \(s.displayCount) display(s), "
                    + "\(s.applicationCount) app(s)\n").utf8
            ))
            toggleItem.isEnabled = true
            await startCapture()
        } catch {
            FileHandle.standardError.write(Data(("[B7] \(error)\n").utf8))
            statusMenuItem.title = "Status: no capture access — grant Screen Recording"
            toggleItem.isEnabled = false
        }
    }

    private func startCapture() async {
        guard !capturing else { return }
        let meter = blockMeter
        let server = wsServer
        let cap = AudioCapture(
            blockSize: kBlockSize,
            onBlock: { block in
                server.broadcast(block)
                meter.record(blockSamples: block.count)
            },
            onLevel: { [weak self] rms in
                let rmsD = Double(rms)
                let db = rmsD > 0 ? 20 * log10(rmsD) : -120
                let (blkPerSec, _) = meter.sampleAndReset()
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
            capturing = true
            toggleItem.title = "Stop Capture"
            FileHandle.standardError.write(Data("[B7] capture started\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[B7] capture start failed: \(error)\n".utf8))
            statusMenuItem.title = "Status: capture start failed"
        }
    }

    private func stopCapture() async {
        guard capturing, let cap = capture else { return }
        await cap.stop()
        capture = nil
        capturing = false
        toggleItem.title = "Start Capture"
        statusMenuItem.title = "Status: stopped (no audio captured)"
        FileHandle.standardError.write(Data("[B7] capture stopped\n".utf8))
    }

    // MARK: Menu actions

    @objc private func toggleCapture() {
        Task { @MainActor in
            if capturing { await stopCapture() } else { await startCapture() }
        }
    }

    @objc private func copyToken() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(wsServer.token, forType: .string)
        FileHandle.standardError.write(Data("[B7] token copied to pasteboard\n".utf8))
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
    app.setActivationPolicy(.accessory)
    app.run()
}
