import Foundation

/// Persistent WebSocket to Supabase Realtime (faster than one HTTP request per line).
/// Used by the broadcast extension; falls back to REST when not connected.
final class RealtimeSocket {
    static let shared = RealtimeSocket()

    private let q = DispatchQueue(label: "sard.ws")
    private var task: URLSessionWebSocketTask?
    private var joined = false
    private var ref = 0
    private var joinRef = "1"
    private var heartbeat: DispatchSourceTimer?
    private var wanted = false
    private var topic: String { "realtime:" + Config.channel }

    func connect() { q.async { self.wanted = true; self.open() } }

    func disconnect() {
        q.async {
            self.wanted = false
            self.heartbeat?.cancel(); self.heartbeat = nil
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil; self.joined = false
        }
    }

    /// Returns false if the socket is not ready (caller should use REST).
    func broadcast(event: String, payload: [String: String]) -> Bool {
        q.sync {
            guard joined, let t = task else { return false }
            push(t, ["topic": topic, "event": "broadcast", "join_ref": joinRef,
                     "payload": ["type": "broadcast", "event": event, "payload": payload]])
            return true
        }
    }

    // MARK: - private (always on q)

    private func open() {
        guard task == nil, !Config.supabaseURL.isEmpty else { return }
        let host = Config.supabaseURL.replacingOccurrences(of: "https://", with: "wss://")
        guard let url = URL(string: host + "/realtime/v1/websocket?apikey=" + Config.supabaseKey + "&vsn=1.0.0") else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t; joined = false
        t.resume()
        ref += 1; joinRef = String(ref)
        push(t, ["topic": topic, "event": "phx_join", "join_ref": joinRef,
                 "payload": ["config": ["broadcast": ["self": false, "ack": false],
                                        "presence": ["key": ""], "private": false]]])
        listen(t)

        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            guard let self, let t = self.task else { return }
            self.push(t, ["topic": "phoenix", "event": "heartbeat", "payload": [String: String]()])
        }
        timer.resume()
        heartbeat = timer
    }

    private func push(_ t: URLSessionWebSocketTask, _ msg: [String: Any]) {
        var m = msg
        ref += 1; m["ref"] = String(ref)
        guard let data = try? JSONSerialization.data(withJSONObject: m),
              let s = String(data: data, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    private func listen(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, s.contains("phx_reply"), s.contains(self.topic), s.contains("\"ok\"") {
                    self.q.async { self.joined = true }
                }
                self.listen(t)
            case .failure:
                self.q.async {
                    guard self.task === t else { return }
                    self.task = nil; self.joined = false
                    if self.wanted {
                        self.q.asyncAfter(deadline: .now() + 2) { self.open() }
                    }
                }
            }
        }
    }
}
