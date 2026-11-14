import Combine
import Foundation

/// Repositories the user added and the sources installed from them.
///
/// Storage for this first build is one small JSON file. The library database
/// (SQLite with migrations) arrives with the library itself in Stage 1.
@MainActor
final class SourceStore: ObservableObject {
    struct Repo: Identifiable {
        var url: String
        var index: RepoIndex?
        var error: String?
        var loading = false
        var id: String { url }
    }

    private struct Saved: Codable {
        var repos: [String]
        var installed: [InstalledSource]
    }

    @Published private(set) var repos: [Repo] = []
    @Published private(set) var installed: [InstalledSource] = []

    private var runtimes: [String: SourceRuntime] = [:]
    private let savedURL = AppPaths.support.appendingPathComponent("sources.json")
    private let sourcesDir = AppPaths.support.appendingPathComponent("Sources", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: savedURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            repos = saved.repos.map { Repo(url: $0) }
            installed = saved.installed
        }
        for repo in repos { Task { await refresh(repo.url) } }
    }

    private func save() {
        let saved = Saved(repos: repos.map { $0.url }, installed: installed)
        do {
            try JSONEncoder().encode(saved).write(to: savedURL, options: .atomic)
        } catch {
            Log.error("Could not save sources.json: \(error.localizedDescription)")
        }
    }

    // MARK: Repositories

    /// Cleans up what the user typed. Returns nil unless it is an https URL.
    static func normalizedRepoURL(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/versioning.json") { text.removeLast("/versioning.json".count) }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return text
    }

    func addRepo(_ input: String) async -> String? {
        guard let url = SourceStore.normalizedRepoURL(input) else {
            return "Enter a full https:// address."
        }
        if repos.contains(where: { $0.url == url }) { return "That repository is already added." }
        repos.append(Repo(url: url))
        save()
        await refresh(url)
        return repos.first(where: { $0.url == url })?.error
    }

    func removeRepo(_ url: String) {
        repos.removeAll { $0.url == url }
        save()
    }

    func refresh(_ url: String) async {
        guard let i = repos.firstIndex(where: { $0.url == url }) else { return }
        repos[i].loading = true
        var index: RepoIndex?
        var message: String?
        do {
            guard let indexURL = URL(string: url + "/versioning.json") else { throw SourceError(message: "Bad address") }
            var request = URLRequest(url: indexURL)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw SourceError(message: "The repository answered HTTP \(status).") }
            guard data.count < 2_000_000 else { throw SourceError(message: "The repository index is too large.") }
            do {
                index = try JSONDecoder().decode(RepoIndex.self, from: data)
            } catch {
                throw SourceError(message: "This address does not hold a valid versioning.json.")
            }
        } catch {
            message = error.localizedDescription
            Log.error("Repository \(url): \(error.localizedDescription)")
        }
        guard let j = repos.firstIndex(where: { $0.url == url }) else { return }
        repos[j].loading = false
        repos[j].error = message
        if let index = index { repos[j].index = index }
    }

    // MARK: Sources

    private static func isSafeId(_ id: String) -> Bool {
        // The id becomes a folder name, so allow only harmless characters.
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func bundleURL(_ id: String) -> URL {
        sourcesDir.appendingPathComponent(id, isDirectory: true).appendingPathComponent("source.js")
    }

    func installedVersion(_ id: String) -> String? {
        installed.first(where: { $0.id == id })?.version
    }

    /// Downloads a source's bundle. Used for both install and update.
    func install(_ source: RepoSource, from repo: Repo) async -> String? {
        guard repo.index?.isCompatible == true else { return "This repository is not built for the 0.8 format." }
        guard SourceStore.isSafeId(source.id) else { return "The source has an invalid id." }
        do {
            guard let url = URL(string: "\(repo.url)/\(source.id)/source.js") else { throw SourceError(message: "Bad address") }
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw SourceError(message: "Download failed with HTTP \(status).") }
            guard data.count > 1000, data.count < 8_000_000 else { throw SourceError(message: "The source file has an unexpected size.") }
            guard let text = String(data: data, encoding: .utf8), text.contains("Sources") else {
                throw SourceError(message: "The file is not a source bundle.")
            }
            let target = bundleURL(source.id)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        } catch {
            Log.error("Install \(source.id): \(error.localizedDescription)")
            return error.localizedDescription
        }
        let entry = InstalledSource(id: source.id, name: source.name, version: source.version, repoURL: repo.url,
                                    contentRating: source.contentRating, websiteBaseURL: source.websiteBaseURL,
                                    intents: source.intents)
        installed.removeAll { $0.id == source.id }
        installed.append(entry)
        installed.sort { $0.name.lowercased() < $1.name.lowercased() }
        runtimes[source.id] = nil   // an update must load the new file
        save()
        Log.info("Installed \(source.name) \(source.version)")
        return nil
    }

    func uninstall(_ id: String) {
        installed.removeAll { $0.id == id }
        runtimes[id] = nil
        try? FileManager.default.removeItem(at: sourcesDir.appendingPathComponent(id, isDirectory: true))
        save()
    }

    /// The running JavaScript context for a source (created on first use).
    func runtime(for id: String) -> SourceRuntime {
        if let existing = runtimes[id] { return existing }
        let dir = sourcesDir.appendingPathComponent(id, isDirectory: true)
        let made = SourceRuntime(sourceId: id, bundleURL: bundleURL(id), stateURL: dir.appendingPathComponent("state.json"))
        runtimes[id] = made
        return made
    }
}
