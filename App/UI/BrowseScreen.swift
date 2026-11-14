import SwiftUI

/// Home sections and search for one source.
struct BrowseScreen: View {
    let source: InstalledSource
    let runtime: SourceRuntime

    @State private var sections: [HomeSection] = []
    @State private var homeLoading = false
    @State private var homeError: String?

    @State private var query = ""
    @State private var results: [PartialManga]?
    @State private var nextPage: JSONValue?
    @State private var searching = false
    @State private var searchError: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            if results != nil || searching || searchError != nil {
                searchContent
            } else {
                homeContent
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(source.name)")
        .onSubmit(of: .search) { Task { await search(reset: true) } }
        .onChange(of: query) { text in
            if text.isEmpty { results = nil; searchError = nil; nextPage = nil }
        }
        .task { if sections.isEmpty { await loadHome() } }
    }

    // MARK: Home

    @ViewBuilder
    private var homeContent: some View {
        if homeLoading && sections.isEmpty {
            ProgressView("Loading…").padding(40)
        } else if let error = homeError, sections.isEmpty {
            ErrorBox(message: error) { Task { await loadHome() } }
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(.title3.weight(.semibold)).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(Array((section.items ?? []).enumerated()), id: \.offset) { _, manga in
                                    link(manga)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
    }

    private func link(_ manga: PartialManga) -> some View {
        NavigationLink(destination: MangaScreen(runtime: runtime, mangaId: manga.mangaId, fallbackTitle: manga.title, fallbackCover: manga.image)) {
            MangaCell(runtime: runtime, manga: manga)
        }
        .buttonStyle(.plain)
    }

    private func loadHome() async {
        homeLoading = true
        homeError = nil
        let collected = SectionCollector()
        do {
            _ = try await runtime.callRaw("getHomePageSections", [], onSection: { data in
                if let section = try? JSONDecoder().decode(HomeSection.self, from: data) { collected.add(section) }
            })
            sections = collected.all().filter { !($0.items ?? []).isEmpty }
            if sections.isEmpty { homeError = "The source returned an empty home page." }
        } catch {
            homeError = error.localizedDescription
        }
        homeLoading = false
    }

    // MARK: Search

    @ViewBuilder
    private var searchContent: some View {
        if let error = searchError, (results ?? []).isEmpty {
            ErrorBox(message: error) { Task { await search(reset: true) } }
        } else if searching && results == nil {
            ProgressView("Searching…").padding(40)
        } else if let results = results {
            if results.isEmpty {
                Text("No results for “\(query)”.").foregroundColor(.secondary).padding(40)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, manga in
                        link(manga)
                    }
                }
                .padding()
                if nextPage != nil {
                    Button(searching ? "Loading…" : "Load more") { Task { await search(reset: false) } }
                        .buttonStyle(.bordered)
                        .disabled(searching)
                        .padding(.bottom, 24)
                }
            }
        }
    }

    private func search(reset: Bool) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !searching else { return }
        searching = true
        searchError = nil
        if reset { results = nil; nextPage = nil }
        let request: [String: Any] = ["title": text, "includedTags": [Any](), "excludedTags": [Any](), "parameters": [String: Any]()]
        do {
            let page = try await runtime.call(PagedResults.self, "getSearchResults", [request, nextPage?.any ?? NSNull()])
            results = (results ?? []) + (page.results ?? [])
            if let meta = page.metadata, !meta.isNull { nextPage = meta } else { nextPage = nil }
        } catch {
            searchError = error.localizedDescription
            if results == nil { results = [] }
        }
        searching = false
    }
}

/// Collects home sections that arrive on the source's own thread.
/// A source may report the same section twice (empty first, filled later);
/// the last version wins and the original order is kept.
final class SectionCollector {
    private let lock = NSLock()
    private var order: [String] = []
    private var byId: [String: HomeSection] = [:]

    func add(_ section: HomeSection) {
        lock.lock()
        if byId[section.id] == nil { order.append(section.id) }
        byId[section.id] = section
        lock.unlock()
    }

    func all() -> [HomeSection] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { byId[$0] }
    }
}
