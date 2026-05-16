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
        } catch {
            line = "No capture access — grant Screen Recording"
            FileHandle.standardError.write(Data(
                ("[B2] \(error)\n").utf8
            ))
        }
        statusMenuItem.title = "Status: \(line)"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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
