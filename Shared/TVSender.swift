import Foundation

/// Sends a subtitle line to the Samsung TV app through Supabase Realtime (REST broadcast).
enum TVSender {
    static func debug(_ text: String) { post(event: "dbg", payload: ["text": text]) }

    static func send(_ text: String, en: String = "") { post(event: "sub", payload: ["text": text, "en": en]) }

    private static func post(event: String, payload: [String: String]) {
        guard !Config.supabaseURL.isEmpty,
              let url = URL(string: Config.supabaseURL + "/realtime/v1/api/broadcast") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue(Config.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": [[
                "topic": Config.channel,
                "event": event,
                "payload": payload,
                "private": false
            ]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}
