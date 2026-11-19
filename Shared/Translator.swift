import Foundation
#if canImport(Translation)
import Translation
#endif

/// Translation pipeline: cache -> glossary -> Google (free monthly quota) -> Apple on-device.
actor Translator {
    static let shared = Translator()

    private var cache: [String: String] = [:]
    private var dirty = 0
    private let cacheURL: URL
    private var appleSession: AnyObject?

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appendingPathComponent("sard_cache.json")
        if let d = try? Data(contentsOf: cacheURL),
           let c = try? JSONDecoder().decode([String: String].self, from: d) {
            cache = c
        }
    }

    func translate(_ en: String) async -> String? {
        let key = Glossary.normalize(en)
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        if let g = Glossary.shared.wholeLine(en) { return g }

        let prepared = Glossary.shared.applyInline(en)
        var result: String?
        if !Config.googleKey.isEmpty, GoogleQuota.canUse(prepared.count) {
            result = await google(prepared)
            if result != nil { GoogleQuota.add(prepared.count) }
        }
        if result == nil { result = await apple(prepared) }

        if let r = result {
            cache[key] = r
            dirty += 1
            if dirty >= 10 { save() }
        }
        return result
    }

    func save() {
        dirty = 0
        if let d = try? JSONEncoder().encode(cache) { try? d.write(to: cacheURL) }
    }

    private func google(_ text: String) async -> String? {
        var comps = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        comps.queryItems = [URLQueryItem(name: "key", value: Config.googleKey)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject:
            ["q": text, "source": "en", "target": "ar", "format": "text"])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let arr = d["translations"] as? [[String: Any]],
              let t = arr.first?["translatedText"] as? String else { return nil }
        return t
    }

    private func apple(_ text: String) async -> String? {
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            do {
                let session: TranslationSession
                if let s = appleSession as? TranslationSession {
                    session = s
                } else {
                    session = try TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                                     target: Locale.Language(identifier: "ar"))
                    appleSession = session
                }
                let response = try await session.translate(text)
                return response.targetText
            } catch {
                appleSession = nil
                return nil
            }
        }
        #endif
        return nil
    }
}

/// Keeps Google usage under the free 500,000 characters per month.
enum GoogleQuota {
    static let limit = 480_000
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sard_quota.json")
    }
    private static func month() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date())
    }
    private static func load() -> [String: Int] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: d)) ?? [:]
    }
    static func used() -> Int { load()[month()] ?? 0 }
    static func canUse(_ chars: Int) -> Bool { used() + chars <= limit }
    static func add(_ n: Int) {
        var d = load(); d[month()] = (d[month()] ?? 0) + n
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: url) }
    }
}
