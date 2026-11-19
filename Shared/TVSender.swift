import Foundation

/// Sends a subtitle line to the Samsung TV app through Supabase Realtime (REST broadcast).
enum TVSender {
    static func send(_ text: String, en: String = "") {
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
                "event": "sub",
                "payload": ["text": text, "en": en],
                "private": false
            ]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}
