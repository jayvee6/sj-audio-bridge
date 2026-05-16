// B5: localhost WebSocket server.
//
// Non-negotiables (security model):
//   - Binds 127.0.0.1 ONLY (requiredLocalEndpoint loopback) — never 0.0.0.0.
//   - A random per-launch token is generated here; B6 enforces it in the
//     handshake (any web page on the machine could otherwise connect and
//     siphon system audio).
//
// Uses Apple's Network.framework NWProtocolWebSocket — the OS performs the
// HTTP upgrade + RFC6455 framing, so there is no third-party dependency and
// no hand-rolled framing to get wrong.
//
// B5 scope: listener up on loopback, accepts WS connections, sends a JSON
// hello, logs connect/disconnect, owns the token. Token ENFORCEMENT + binary
// PCM frames are B6.

import Foundation
import Network
import Security

final class WSServer: @unchecked Sendable {
    let port: UInt16
    let token: String

    private let queue = DispatchQueue(label: "dev.studiojoe.sjaudiobridge.ws")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16 = 17653) {
        self.port = port
        self.token = WSServer.makeToken()
    }

    /// 128-bit cryptographically-random hex token, fresh every launch.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            // Fall back to UUID entropy rather than a predictable token.
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    var endpointURL: String { "ws://127.0.0.1:\(port)" }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcp)
        // Bind loopback ONLY — the core of the security model.
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
            switch state {
            case .ready:
                FileHandle.standardError.write(Data(
                    "[B5] WS listening on ws://127.0.0.1:\(self.port)\n".utf8
                ))
            case let .failed(err):
                FileHandle.standardError.write(Data(
                    "[B5] listener failed: \(err)\n".utf8
                ))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        FileHandle.standardError.write(Data(
            "[B5] token=\(token) — clients must present this in B6 handshake\n".utf8
        ))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                FileHandle.standardError.write(Data("[B5] client connected\n".utf8))
                self?.sendHello(conn)
                self?.receiveLoop(conn)
            case .cancelled, .failed:
                self?.connections[id] = nil
                FileHandle.standardError.write(Data("[B5] client disconnected\n".utf8))
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func sendHello(_ conn: NWConnection) {
        let hello = #"{"type":"hello","server":"sj-audio-bridge","version":"0.1.0","note":"B5 — token enforcement + binary PCM frames land in B6"}"#
        sendText(hello, on: conn)
    }

    private func sendText(_ text: String, on conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(
            content: Data(text.utf8),
            contentContext: ctx,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            if let error {
                FileHandle.standardError.write(Data("[B5] receive error: \(error)\n".utf8))
                return
            }
            if let data, !data.isEmpty {
                let preview = String(decoding: data.prefix(120), as: UTF8.self)
                FileHandle.standardError.write(Data(
                    "[B5] recv \(data.count)B: \(preview)\n".utf8
                ))
            }
            _ = context
            self?.receiveLoop(conn)
        }
    }
}
