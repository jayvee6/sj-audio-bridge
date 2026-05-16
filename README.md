<div align="center">

# SJAudioBridge

**System audio in any browser — the way Zoom does it, not a hack.**

A tiny notarized macOS menubar app that captures whatever's playing on your
Mac and streams it over a token-gated localhost WebSocket. Point a browser at
it and you get bit-perfect, system-wide audio for music visualization —
**including Safari and Firefox**, where the browser can't capture system
audio at all.

[Download](https://github.com/jayvee6/sj-audio-bridge/releases/latest) ·
[Website](https://jayvee6.github.io/sj-audio-bridge/) ·
[Web library (`sj-audio`)](https://github.com/jayvee6/sj-audio)

macOS 14+ · Notarized (Developer ID) · MIT

</div>

---

## Why this exists

Browsers deliberately can't capture system audio. `getDisplayMedia({audio})`
is Chromium-desktop only, captures *tab* not *system* audio on macOS, and is
often DSP-mangled. Safari and Firefox silently drop the audio entirely. DRM
streams (Spotify, Apple Music) read as silence.

Zoom, Webex and Teams don't "work around" this — their **desktop clients are
native apps** using an OS audio API. SJAudioBridge does exactly that: a
signed + notarized helper uses **ScreenCaptureKit** to capture the system
mix, then hands it to the browser over a WebSocket. The page just reads a
socket, so it works in **every** browser, at full fidelity, DRM included.

```
┌─ SJAudioBridge.app (this repo, Swift, macOS 14+) ───────────┐
│  ScreenCaptureKit  →  Float32 mono PCM  →  WebSocket          │
│  (system audio mix)   (1024-sample blocks)  127.0.0.1 + token │
└───────────────────────────────┬──────────────────────────────┘
                                 │  ws://127.0.0.1:17653
                                 │  JSON handshake + binary PCM
┌────────────────────────────────▼─────────────────────────────┐
│  Any browser — sj-audio createNativeBridgeSource({ token })   │
│  PCM → AudioWorklet → analyzer → AudioFrame → your visualizer │
└───────────────────────────────────────────────────────────────┘
```

## Try it in 60 seconds

1. **Download** the latest `SJAudioBridge-<version>.zip` from
   [Releases](https://github.com/jayvee6/sj-audio-bridge/releases/latest),
   unzip, drag **SJAudioBridge.app** to `/Applications`, open it.
2. Approve the **Screen Recording** prompt, then **quit & relaunch**
   (macOS only applies a fresh grant after relaunch).
3. The menubar waveform icon should read `capturing — <dBFS> · <N> blk/s`.
4. Menubar → **Copy Connection Token**.
5. Open the [`sj-audio` native-bridge demo](https://github.com/jayvee6/sj-audio/blob/main/examples/esm-native-bridge.html),
   paste the token, **Connect**, play music anywhere.

> **Why does an audio tool need Screen Recording?** ScreenCaptureKit is
> TCC-gated under Screen Recording even for audio-only capture.
> SJAudioBridge requests nothing else, captures **no video** (a 2×2 / 1 fps
> dummy surface that is never read), and sets `excludesCurrentProcessAudio`
> so it never records itself.

## Menubar

| Item | Action |
|---|---|
| **Status** | live `dBFS · blk/s`, or the current access / error state |
| **Endpoint** | `ws://127.0.0.1:17653` |
| **Copy Connection Token** | puts the per-launch token on the clipboard |
| **Stop / Start Capture** | toggles capture (the macOS recording indicator follows it) |
| **Quit** | terminate |

## Wire protocol v1

The WebSocket binds **`127.0.0.1` only** and requires the per-launch token.
The protocol is intentionally tiny and cross-platform (a future Windows
WASAPI-loopback helper will speak it unchanged).

```
1. server → client   text    {"type":"hello","protocol":1}
2. client → server   text    {"type":"auth","token":"<hex>"}
3a. bad / absent token   →   server closes the connection
                              (silent clients dropped after a 3 s timeout)
3b. valid token          →   server text:
    {"type":"ready","sampleRate":48000,"channels":1,
     "blockSize":1024,"format":"f32le","protocol":1}
4. server → client   BINARY  1024 little-endian Float32 mono samples
                              (4096 bytes) per frame, ~46.9 frames/s.
                              Realtime: a frame is dropped (never queued)
                              for any client whose prior send is in flight.
```

### Getting the token

- **Menubar → Copy Connection Token**, or
- `~/Library/Application Support/SJAudioBridge/token` — a `0600` cookie
  file (conventional, cf. Jupyter / BitTorrent) for local scripts.

The token is **regenerated on every launch**.

### Minimal client (Node ≥ 22 — built-in `WebSocket`)

```js
import { readFileSync } from 'node:fs';

const token = readFileSync(
  `${process.env.HOME}/Library/Application Support/SJAudioBridge/token`,
  'utf8',
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

### In the browser (recommended)

Use [`sj-audio`](https://github.com/jayvee6/sj-audio) — it injects the PCM
through an AudioWorklet into the same analysis pipeline every other source
uses, so any sj-audio visualizer works with system audio for free:

```js
import { createNativeBridgeSource } from
  'https://cdn.jsdelivr.net/gh/jayvee6/sj-audio@v0.2.0/dist/sj-audio.esm.js';

const source = createNativeBridgeSource({ token });   // from the menubar
source.onFrame((f) => drawBars(f.magnitudesSmooth));  // 32 mel bands
await source.start();
```

## Security model

This is a local audio tap; trust is the whole point.

- WebSocket binds **`127.0.0.1` only** — never `0.0.0.0`.
- 128-bit `SecRandom` token, **regenerated every launch**, required in the
  handshake and **constant-time compared**. No token → no audio, connection
  closed. A 3 s timeout drops silent clients.
- `excludesCurrentProcessAudio` — the bridge never captures its own output.
- Notarization credentials live in the **keychain**, never in this repo;
  `.p8` / `.cer` / `.p12` are git-ignored.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Status: *no capture access* | Screen Recording not granted. System Settings ▸ Privacy & Security ▸ Screen Recording → enable SJAudioBridge, then **quit & relaunch**. |
| Client gets `bridge-unreachable` | App not running, or capture stopped. Check the menubar status. |
| Client gets `auth-failed` | Stale token — it rotates each launch. Re-copy from the menubar. |
| dBFS stuck at `-120` | Genuinely silent, or audio is on a device the system mix doesn't include. Play audio through the default output. |
| Moved the app and macOS re-prompts | TCC tracks by path for first grant; re-approve + relaunch once. |

## Build from source

Requires a Swift 6 toolchain and macOS 14+.

```bash
swift build                  # debug build
Scripts/package_app.sh       # → SJAudioBridge.app (Developer ID + hardened runtime)
Scripts/sign-and-notarize.sh # release: build → sign → notarize → staple → zip
```

`version.env` carries `APP_NAME`, `BUNDLE_ID`, `APP_IDENTITY`,
`NOTARY_PROFILE`. Notarization auth is a keychain profile created once:

```bash
xcrun notarytool store-credentials "sj-audio-bridge-notary" \
  --key <AuthKey_XXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>
```

No secrets ever enter the repo.

## Roadmap

- **macOS** — shipped (v0.1.0), ScreenCaptureKit.
- **Windows** — WASAPI-loopback helper speaking the same wire protocol v1
  (the protocol is cross-platform by design).

## Related

- **[sj-audio](https://github.com/jayvee6/sj-audio)** — the cross-browser web
  audio capture + analysis library. `createNativeBridgeSource()` consumes
  this bridge; four other sources (mic, media element, display, file) need no
  helper.

## License

MIT © Joe Villarreal
