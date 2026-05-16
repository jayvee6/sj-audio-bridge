# SJAudioBridge

Native macOS menubar helper that captures **system audio** via
ScreenCaptureKit and streams it over a **token-gated localhost WebSocket** to
[`sj-audio`](https://github.com/jayvee6/sj-audio)'s `createNativeBridgeSource()`
web adapter — giving any browser bit-perfect, system-wide audio for music
visualization.

This is the same architecture Zoom / Webex / Teams use to grab computer audio
(a native app + an OS audio API), not an in-page hack. The browser sandbox
blocks system-audio capture by design; a tiny signed + notarized helper
sidesteps it cleanly, and because the browser just reads a WebSocket it works
in **every** browser (Safari/Firefox included, where `getDisplayMedia` audio
is unavailable).

## Install

1. Download `SJAudioBridge-<version>.zip` from
   [Releases](https://github.com/jayvee6/sj-audio-bridge/releases), unzip,
   move **SJAudioBridge.app** to `/Applications`.
2. Launch it. A **waveform icon** appears in the menubar (no Dock icon).
3. macOS prompts for **Screen Recording** — approve it.
   (Or: System Settings ▸ Privacy & Security ▸ Screen Recording → enable
   **SJAudioBridge**.)
4. **Quit and relaunch** — macOS only applies a fresh Screen Recording grant
   after relaunch.
5. The menubar Status line should read `capturing — <dBFS> · <N> blk/s`.

The app is notarized and stapled (Developer ID: Jose Villarreal, ATGGQ68RUK),
so Gatekeeper opens it without a right-click bypass.

> **Why Screen Recording for audio?** ScreenCaptureKit is TCC-gated under the
> Screen Recording permission even when only audio is captured. SJAudioBridge
> requests nothing else, captures no video (a 2×2/1 fps dummy surface that's
> never read), and sets `excludesCurrentProcessAudio` so it never records
> itself.

## Menubar

| Item | Action |
|---|---|
| Status | live `dBFS · blk/s` (or access/error state) |
| Endpoint | `ws://127.0.0.1:17653` |
| Copy Connection Token | puts the per-launch token on the clipboard |
| Stop / Start Capture | toggles ScreenCaptureKit capture (the macOS recording indicator follows it) |
| Quit | terminate |

## Connecting a client (wire protocol v1)

The WebSocket binds **`127.0.0.1` only** and requires the per-launch token.

```
1. server → client   text    {"type":"hello","protocol":1}
2. client → server    text    {"type":"auth","token":"<hex>"}
3a. bad / absent token  →  server closes the connection
    (silent clients are dropped after a 3 s auth timeout)
3b. valid token         →  server text:
    {"type":"ready","sampleRate":48000,"channels":1,
     "blockSize":1024,"format":"f32le","protocol":1}
4. server → client   BINARY  1024 little-endian Float32 mono samples
                              (4096 bytes) per frame, ~46.9 frames/s.
                              Realtime: a frame is dropped (never queued)
                              for any client whose previous send is still
                              in flight.
```

### Where the token comes from

- **Menubar → Copy Connection Token** (paste into the web app), or
- `~/Library/Application Support/SJAudioBridge/token` — a `0600`
  cookie-file (conventional, cf. Jupyter/BitTorrent) for local
  clients/scripts. The token is **fresh every launch**.

### Minimal client (Node ≥ 22, built-in `WebSocket`)

```js
import { readFileSync } from 'node:fs';
const token = readFileSync(
  `${process.env.HOME}/Library/Application Support/SJAudioBridge/token`, 'utf8'
).trim();
const ws = new WebSocket('ws://127.0.0.1:17653');
ws.binaryType = 'arraybuffer';
ws.onmessage = (e) => {
  if (typeof e.data === 'string') {
    const m = JSON.parse(e.data);
    if (m.type === 'hello') ws.send(JSON.stringify({ type: 'auth', token }));
    if (m.type === 'ready') console.log('streaming', m);
  } else {
    const pcm = new Float32Array(e.data); // 1024 mono samples
    // → feed your analyzer / visualizer
  }
};
```

In the browser this is `sj-audio`'s `createNativeBridgeSource({ token })`
(ships in sj-audio v0.2.0) — it injects the PCM through an AudioWorklet into
the existing analysis pipeline, so visualizers behave identically to every
other sj-audio source.

## Security model (non-negotiable)

- WebSocket binds **`127.0.0.1` only** — never `0.0.0.0`.
- 128-bit `SecRandom` token, **regenerated every launch**, required in the
  handshake (constant-time compared). No token → no audio, connection closed.
- `excludesCurrentProcessAudio` — the bridge never captures its own output.
- Notarization credentials live in the **keychain** (profile
  `sj-audio-bridge-notary`), never in this repo. `.p8`/`.cer`/`.p12` are
  git-ignored.

## Build from source

```bash
swift build                       # debug
Scripts/package_app.sh            # → SJAudioBridge.app (Developer ID, hardened runtime)
Scripts/sign-and-notarize.sh      # release: build → sign → notarize → staple → zip
```

`version.env` carries `APP_NAME`, `BUNDLE_ID`, `APP_IDENTITY`,
`NOTARY_PROFILE`. Notarization auth is a keychain profile created once:

```bash
xcrun notarytool store-credentials "sj-audio-bridge-notary" \
  --key <AuthKey_XXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>
```

## Roadmap

- macOS: shipped (v0.1.0).
- Windows: a WASAPI-loopback helper speaking the **same wire protocol v1**
  (planned — the protocol is cross-platform by design).

## License

MIT
