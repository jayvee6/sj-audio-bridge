# SJAudioBridge

Native macOS menubar helper that captures system audio via **ScreenCaptureKit**
and streams it over a **localhost WebSocket** to [`sj-audio`](https://github.com/jayvee6/sj-audio)'s
`createNativeBridgeSource()` web adapter — giving any browser bit-perfect,
system-wide audio for music visualization. This is the same architecture
Zoom / Webex / Teams use to grab computer audio (a native app + OS audio API),
not an in-page hack.

## Why

Browser `getDisplayMedia` audio is Chromium-only, tab-not-system on macOS, and
often DSP-mangled. A tiny signed+notarized native helper sidesteps the sandbox
entirely; the browser just reads a WebSocket, so it works in **every** browser.

## Status

v0.1.0 — scaffold (B0). Build: `swift build`. Capture + WS server land in
B1–B7. See `.claude/handoff-2026-05-16.md` for the chunk log.

## Security model (non-negotiable)

- WebSocket binds **`127.0.0.1` only** — never `0.0.0.0`.
- A **random per-launch token** must be presented in the WS handshake or the
  connection is closed. Prevents any web page from silently siphoning audio.
- `excludesCurrentProcessAudio` so the bridge never captures its own output.
- Notarization credentials live in the **keychain** (profile
  `sj-audio-bridge-notary`), never in this repo.

## Requirements

- macOS 14+
- Screen Recording permission (ScreenCaptureKit is TCC-gated even for
  audio-only on macOS 14)

## License

MIT
