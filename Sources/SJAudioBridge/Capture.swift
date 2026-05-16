// B2: ScreenCaptureKit access + shareable-content enumeration.
//
// Screen Recording is a TCC-gated permission on macOS — ScreenCaptureKit
// (even audio-only) requires it. We:
//   1. Preflight the grant (CGPreflightScreenCaptureAccess).
//   2. If absent, request it (CGRequestScreenCaptureAccess) → system prompt
//      on first launch; thereafter the user toggles it in
//      System Settings ▸ Privacy & Security ▸ Screen Recording.
//   3. Enumerate SCShareableContent (displays/apps) to confirm the grant and
//      pick a capture target (B3 builds the SCStream on this).
//
// Stable Developer ID signing (version.env APP_IDENTITY) keeps the grant
// sticky across rebuilds — ad-hoc signing changes the cdhash and re-prompts.

import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureAccess {
    /// True if Screen Recording is already granted (no prompt shown).
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt on first call if not yet granted.
    /// Returns the post-request grant state. Subsequent denials require the
    /// user to flip the toggle in System Settings (no re-prompt).
    @discardableResult
    static func request() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
}

struct ShareableContentSummary {
    let displayCount: Int
    let applicationCount: Int
    let firstDisplayDescription: String?
}

enum ShareableContentError: Error, CustomStringConvertible {
    case permissionDenied
    case sckFailure(String)

    var description: String {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission not granted. Grant it in "
                + "System Settings ▸ Privacy & Security ▸ Screen Recording, "
                + "then relaunch SJAudioBridge."
        case let .sckFailure(msg):
            return "ScreenCaptureKit error: \(msg)"
        }
    }
}

enum ShareableContent {
    /// Enumerate capturable displays/apps. Throws `.permissionDenied` if the
    /// TCC grant is missing (SCShareableContent fails closed without it).
    static func summarize() async throws -> ShareableContentSummary {
        guard ScreenCaptureAccess.isGranted() else {
            throw ShareableContentError.permissionDenied
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let first = content.displays.first
            let desc = first.map {
                "display \($0.displayID) \($0.width)x\($0.height)"
            }
            return ShareableContentSummary(
                displayCount: content.displays.count,
                applicationCount: content.applications.count,
                firstDisplayDescription: desc
            )
        } catch {
            throw ShareableContentError.sckFailure(String(describing: error))
        }
    }
}
