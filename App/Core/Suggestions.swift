import Foundation

/// One "Suggested for you" row: a genre, why it was picked, and titles.
struct SuggestionRow: Identifiable {
    let tag: Tag
    let reason: String
    var items: [PartialManga]
    var id: String { tag.id }
}

/// Builds suggestions on the iPad from the library and reading history.
/// Nothing is sent anywhere except ordinary genre searches to the source.
///
/// Method: every genre of every title you saved or read gets points (more if
/// the title is in the library, more if you read it in the last two weeks).
/// The best-scoring genres that the current source also knows are searched,
/// and titles you already have are removed from the results.
enum Suggestions {
    /// Used when the library is still empty (Rev's stated favourites first).
    private static let starters = ["romance", "shonen", "action", "comedy", "fantasy"]

    /// "Shounen", "shonen" and "Shōnen" should all match.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let letters = folded.filter { $0.isLetter || $0.isNumber }
        return letters.replacingOccurrences(of: "ou", with: "o")
    }

    struct Pick {
        let tag: Tag
        let reason: String
    }

    static func picks(taste: [StoredManga], genres: [Tag], limit: Int = 3) -> [Pick] {
        var score: [String: Double] = [:]
        var example: [String: (title: String, time: Double)] = [:]
        let twoWeeksAgo = Date().timeIntervalSince1970 - 14 * 86_400

        for manga in taste {
            let time = manga.lastReadAt ?? 0
            var points = 1.0
            if manga.inLibrary { points += 1 }
            if time > twoWeeksAgo { points += 1 }
            for label in manga.tags {
                let key = normalize(label)
                guard !key.isEmpty else { continue }
                score[key, default: 0] += points
                if example[key] == nil || time > (example[key]?.time ?? 0) {
                    example[key] = (manga.title, time)
                }
            }
        }

        var byKey: [String: Tag] = [:]
        for tag in genres where byKey[normalize(tag.label)] == nil { byKey[normalize(tag.label)] = tag }

        var result: [Pick] = []
        let ranked = score.filter { byKey[$0.key] != nil }.sorted { $0.value > $1.value }
        for (key, _) in ranked.prefix(limit) {
            guard let tag = byKey[key] else { continue }
            let reason = example[key].map { "Because you read \($0.title)" } ?? "From your library"
            result.append(Pick(tag: tag, reason: reason))
        }
        // Not enough history yet: fill up with common genres.
        for key in starters where result.count < limit {
            guard let tag = byKey[key], !result.contains(where: { $0.tag.id == tag.id }) else { continue }
            result.append(Pick(tag: tag, reason: "A popular genre to start with"))
        }
        return result
    }
}
