// B5+B6: localhost WebSocket server + token-gated binary PCM streaming.
//
// Security model (non-negotiable):
//   - Binds 127.0.0.1 ONLY (requiredLocalEndpoint loopback).
//   - A random per-launch token MUST be presented in the first client
//     message; unauthenticated connections receive zero audio and are
//     closed. Any web page on the machine could otherwise siphon system
//     audio over localhost.
//
// Wire protocol (v1) — designed cross-platform so the future Windows
// (WASAPI-loopback) bridge reuses it unchanged:
//   1. server → client  text  {"type":"hello","protocol":1}
//   2. client → server  text  {"type":"auth","token":"<hex>"}
//   3a. bad/absent token →  server closes the connection
//   3b. good token       →  server text {"type":"ready","sampleRate":48000,
//        "channels":1,"blockSize":1024,"format":"f32le","protocol":1}
//   4. server → client  BINARY frames: blockSize little-endian Float32
//      mono samples (1024 → 4096 bytes), realtime — dropped, never queued,
//      for any client whose previous send is still in flight.
//
// Uses Apple's Network.framework NWProtocolWebSocket (OS does RFC6455).

import Foundation
import Network
import Security

let kProtocolVersion = 1
let kBlockSize = 1024

final class WSServer: @unchecked Sendable {
    let port: UInt16
    let token: String

    private let queue = DispatchQueue(label: "dev.studiojoe.sjaudiobridge.ws")
    private var listener: NWListener?

    /// Per-connection state. Every read/write is confined to `queue` (the
    /// listener queue, also the connection callback queue) — that serial
    /// confinement is what makes `@unchecked Sendable` sound here, so the
    /// instance can be captured in NWConnection's @Sendable completions.
    private final class Conn: @unchecked Sendable {
        let nw: NWConnection
        var authed = false
        var sending = false
        init(_ nw: NWConnection) { self.nw = nw }
    }
    private var conns: [ObjectIdentifier: Conn] = [:]

    init(port: UInt16 = 17653) {
        self.port = port
        self.token = WSServer.makeToken()
    }

    private static func makeToken() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, b.count, &b) == errSecSuccess {
            return b.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Constant-time string compare (defense-in-depth; loopback timing
    /// attacks are impractical but the check is free).
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    var endpointURL: String { "ws://127.0.0.1:\(port)" }

    /// `~/Library/Application Support/SJAudioBridge/token` — conventional
    /// local cookie-file pattern (cf. Jupyter, BitTorrent). 0600 so only
    /// this user can read it. Lets local clients/scripts discover the
    /// ephemeral token; browsers still get it via the menubar Copy (B7).
    static var tokenFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("SJAudioBridge", isDirectory: true)
        return base.appendingPathComponent("token", isDirectory: false)
    }

    private func writeTokenFile() {
        let url = WSServer.tokenFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(token.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            FileHandle.standardError.write(Data("[B6] token file write failed: \(error)\n".utf8))
        }
    }

    func start() throws {
        writeTokenFile()
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                FileHandle.standardError.write(Data(
                    "[B6] WS listening ws://127.0.0.1:\(self.port)\n".utf8
                ))
            } else if case let .failed(e) = state {
                FileHandle.standardError.write(Data("[B6] listener failed: \(e)\n".utf8))
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener.start(queue: queue)
        self.listener = listener
        FileHandle.standardError.write(Data("[B6] token=\(token)\n".utf8))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in conns.values { c.nw.cancel() }
        conns.removeAll()
    }

    private func accept(_ nw: NWConnection) {
        let id = ObjectIdentifier(nw)
        let conn = Conn(nw)
        conns[id] = conn
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendText(#"{"type":"hello","protocol":1}"#, conn)
                self.receiveLoop(conn, id: id)
                // Auth deadline: drop silent/unauthed clients after 3 s.
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, let c = self.conns[id], !c.authed else { return }
                    FileHandle.standardError.write(Data("[B6] auth timeout — closing\n".utf8))
                    c.nw.cancel()
                }
            case .cancelled, .failed:
                self.conns[id] = nil
            default:
                break
            }
        }
        nw.start(queue: queue)
    }

    private func receiveLoop(_ conn: Conn, id: ObjectIdentifier) {
        conn.nw.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil { return }
            if let data, !data.isEmpty { self.handleInbound(data, conn) }
            if self.conns[id] != nil { self.receiveLoop(conn, id: id) }
        }
    }

    private func handleInbound(_ data: Data, _ conn: Conn) {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return }

        if type == "auth" {
            let supplied = (obj["token"] as? String) ?? ""
            if WSServer.constantTimeEqual(supplied, token) {
                conn.authed = true
                let ready = #"{"type":"ready","sampleRate":\#(AudioCapture.sampleRate),"channels":1,"blockSize":\#(kBlockSize),"format":"f32le","protocol":\#(kProtocolVersion)}"#
                sendText(ready, conn)
                FileHandle.standardError.write(Data("[B6] client authed\n".utf8))
            } else {
                FileHandle.standardError.write(Data("[B6] bad token — closing\n".utf8))
                conn.nw.cancel()
            }
        }
    }

    private func sendText(_ text: String, _ conn: Conn) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
        conn.nw.send(content: Data(text.utf8), contentContext: ctx,
                     isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Broadcast one mono PCM block as a binary frame to every authed
    /// client. Realtime: a client still mid-send drops this block rather
    /// than building unbounded latency.
    func broadcast(_ block: [Float]) {
        let payload = block.withUnsafeBufferPointer { Data(buffer: $0) }  // f32 native = LE
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.conns.values where conn.authed && !conn.sending {
                conn.sending = true
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let ctx = NWConnection.ContentContext(identifier: "pcm", metadata: [meta])
                conn.nw.send(
                    content: payload, contentContext: ctx, isComplete: true,
                    completion: .contentProcessed { [weak conn] _ in conn?.sending = false }
                )
            }
        }
    }
}
