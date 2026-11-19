import Foundation

/// GTA glossary: whole-line matches, plus safe in-sentence replacements (names and multi-word phrases).
final class Glossary {
    static let shared = Glossary()

    private var full: [String: String] = [:]
    private var inline: [(NSRegularExpression, String)] = []

    /// Single words that are safe to replace inside a sentence (not common English words).
    private static let safeInline: Set<String> = [
        "homie", "homies", "homeboy", "dawg", "bruh", "snitch", "narc", "five-o",
        "feds", "cops", "gat", "shotty", "ammo", "gangbanger", "goons", "hitman",
        "kingpin", "vcpd", "carjack", "carjacking", "getaway"
    ]

    /// Only these sections' multi-word phrases are replaced inside longer sentences.
    /// Everything else is used for whole-line matches only (safer).
    private static let inlinePhraseSections: Set<String> = [
        "police_and_law", "money_and_crime", "weapons_and_action"
    ]

    init() {
        guard let url = Bundle(for: Glossary.self).url(forResource: "gta_glossary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var pairs: [(String, String)] = []
        for (section, value) in obj {
            guard section != "_info", section != "keep", let dict = value as? [String: String] else { continue }
            for (key, ar) in dict {
                full[Glossary.normalize(key)] = ar
                let isName = section == "keep_arabic"
                let alwaysInline = section == "spanish_slang"
                let multiWord = key.split(separator: " ").count >= 2 && Glossary.inlinePhraseSections.contains(section)
                if isName || alwaysInline || multiWord || Glossary.safeInline.contains(key.lowercased()) {
                    pairs.append((key, ar))
                }
            }
        }
        pairs.sort { $0.0.count > $1.0.count }   // longest phrase first
        for (key, ar) in pairs {
            let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: key) + "(?![A-Za-z])"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                inline.append((re, ar))
            }
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    func wholeLine(_ s: String) -> String? { full[Glossary.normalize(s)] }

    func applyInline(_ s: String) -> String {
        var out = s
        for (re, ar) in inline {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: ar))
        }
        return out
    }
}
