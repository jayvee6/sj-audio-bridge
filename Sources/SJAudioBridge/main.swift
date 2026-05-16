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
        menu.addItem(
            withTitle: "Status: idle (capture lands in B3)",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit SJAudioBridge",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
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
