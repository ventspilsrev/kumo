import Foundation

// Data shapes. Field names match what the extensions produce (see
// runtime/prelude.js and the @paperback/types 0.8.7 declarations).
// Almost everything is optional because extensions are third-party code and
// may leave fields out.

// MARK: Repository index (versioning.json)

struct RepoIndex: Codable {
    var buildTime: String?
    var sources: [RepoSource]
    var builtWith: BuiltWith?

    struct BuiltWith: Codable {
        var toolchain: String?
        var types: String?
    }

    /// Only bundles built against the 0.8 typings can run in this app.
    var isCompatible: Bool { builtWith?.types?.hasPrefix("0.8") ?? false }
}

struct RepoSource: Codable, Identifiable {
    var id: String
    var name: String
    var author: String?
    var desc: String?
    var contentRating: String?
    var version: String
    var icon: String?
    var websiteBaseURL: String?
    var intents: Int?
    var tags: [Badge]?

    struct Badge: Codable {
        var text: String
        var type: String?
    }
}

struct InstalledSource: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var version: String
    var repoURL: String
    var contentRating: String?
    var websiteBaseURL: String?
    var intents: Int?
}

// MARK: Extension results

struct PartialManga: Codable {
    var mangaId: String
    var title: String
    var image: String?
    var subtitle: String?
}

struct HomeSection: Codable {
    var id: String
    var title: String
    var items: [PartialManga]?
    var containsMoreItems: Bool?
}

struct PagedResults: Codable {
    var results: [PartialManga]?
    var metadata: JSONValue?
}

struct Tag: Codable {
    var id: String
    var label: String
}

struct TagSection: Codable {
    var id: String
    var label: String
    var tags: [Tag]?
}

struct SourceManga: Codable {
    var id: String?
    var mangaInfo: MangaInfo
}

struct MangaInfo: Codable {
    var titles: [String]?
    var image: String?
    var desc: String?
    var status: String?
    var author: String?
    var artist: String?
    var tags: [TagSection]?
}

struct Chapter: Codable, Identifiable {
    var id: String
    var chapNum: Double?
    var name: String?
    var volume: Double?
    var group: String?
    var time: String?
    var langCode: String?

    var displayTitle: String {
        if let name = name, !name.isEmpty { return name }
        if let n = chapNum { return "Chapter \(n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n))" }
        return id
    }
}

struct ChapterDetails: Codable {
    var id: String?
    var mangaId: String?
    var pages: [String]?
}

/// Any JSON value. Used for the opaque paging `metadata` an extension hands
/// back and expects to receive unchanged on the next call.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Form accepted by JSONSerialization.
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.any }
        case .object(let v): return v.mapValues { $0.any }
        }
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
}
