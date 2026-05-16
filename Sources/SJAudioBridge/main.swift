// SJAudioBridge — native macOS system-audio capture → localhost WebSocket
// for sj-audio's createNativeBridgeSource() web adapter.
//
// B0: placeholder entry point — just proves the SwiftPM target builds and a
// signed .app bundle can be assembled. B1 replaces this with the real
// LSUIElement menubar app (NSStatusItem). No capture logic yet.

import Foundation

let version = "0.1.0"
FileHandle.standardError.write(
    Data("SJAudioBridge \(version) — scaffold build (B0). Menubar app lands in B1.\n".utf8)
)
