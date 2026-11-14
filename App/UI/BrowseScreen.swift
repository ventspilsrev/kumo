import SwiftUI

/// One source: genre chips, home sections and search.
struct BrowseScreen: View {
    let source: InstalledSource
    let runtime: SourceRuntime

    @State private var sections: [HomeSection] = []
    @State private var homeLoading = false
    @State private var homeError: String?
    @State private var genres: [Tag] = []

    @State private var query = ""
    @State private var selectedGenre: Tag?
    @State private var results: [PartialManga]?
    @State private var nextPage: JSONValue?
    @State private var searching = false
    @State private var searchError: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14, alignment: .top)]
    private var showingResults: Bool { results != nil || searching || searchError != nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                genreRow
                if showingResults { searchContent } else { homeContent }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(source.name)")
        .onSubmit(of: .search) {
            selectedGenre = nil
            Task { await search(reset: true) }
        }
        .onChange(of: query) { text in
            if text.isEmpty && selectedGenre == nil { clearResults() }
        }
        .task {
            if sections.isEmpty { await loadHome() }
            if genres.isEmpty { await loadGenres() }
        }
    }

    private func clearResults() {
        results = nil
        searchError = nil
        nextPage = nil
    }

    // MARK: Genres

    @ViewBuilder
    private var genreRow: some View {
        if !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(genres.enumerated()), id: \.offset) { _, tag in
                        Button {
                            if selectedGenre?.id == tag.id {
                                selectedGenre = nil
                                clearResults()
                            } else {
                                selectedGenre = tag
                                query = ""
                                Task { await search(reset: true) }
                            }
                        } label: {
                            Chip(text: tag.label, selected: selectedGenre?.id == tag.id)
                        }
                        .accessibilityLabel("Genre \(tag.label)")
                        .accessibilityAddTraits(selectedGenre?.id == tag.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 44)
        }
    }

    private func loadGenres() async {
        guard let all = try? await runtime.call([TagSection].self, "getSearchTags", []) else { return }
        // Prefer sections that are actually genres; fall back to everything.
        let genreSections = all.filter { ($0.label + $0.id).lowercased().contains("genre") }
        genres = (genreSections.isEmpty ? all : genreSections).flatMap { $0.tags ?? [] }
    }

    // MARK: Home

    @ViewBuilder
    private var homeContent: some View {
        if homeLoading && sections.isEmpty {
            HStack { Spacer(); ProgressView("Loading…"); Spacer() }.padding(40)
        } else if let error = homeError, sections.isEmpty {
            HStack { Spacer(); ErrorBox(message: error) { Task { await loadHome() } }; Spacer() }
        } else {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.title)
                        .font(Theme.serif(.title2, weight: .semibold))
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 20)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array((section.items ?? []).enumerated()), id: \.offset) { _, manga in
                                link(manga)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
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
            var loaded = collected.all().filter { !($0.items ?? []).isEmpty }
            // Some sources return a row without cover addresses (their site
            // changed). Reuse a cover seen for the same title in another row.
            var known: [String: String] = [:]
            for section in loaded {
                for item in section.items ?? [] {
                    if let image = item.image, !image.isEmpty { known[item.mangaId] = image }
                }
            }
            for s in loaded.indices {
                guard var items = loaded[s].items else { continue }
                for i in items.indices where (items[i].image ?? "").isEmpty {
                    items[i].image = known[items[i].mangaId]
                }
                loaded[s].items = items
            }
            sections = loaded
            if sections.isEmpty { homeError = "The source returned an empty home page." }
        } catch {
            homeError = error.localizedDescription
        }
        homeLoading = false
    }

    // MARK: Search and genre results

    @ViewBuilder
    private var searchContent: some View {
        if let genre = selectedGenre {
            Text(genre.label)
                .font(Theme.serif(.title2, weight: .semibold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 20)
        }
        if let error = searchError, (results ?? []).isEmpty {
            HStack { Spacer(); ErrorBox(message: error) { Task { await search(reset: true) } }; Spacer() }
        } else if searching && results == nil {
            HStack { Spacer(); ProgressView("Loading…"); Spacer() }.padding(40)
        } else if let results = results {
            if results.isEmpty {
                Text("Nothing found.").foregroundColor(Theme.muted).padding(40)
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, manga in
                        link(manga)
                    }
                }
                .padding(.horizontal, 20)
                if nextPage != nil {
                    HStack {
                        Spacer()
                        Button(searching ? "Loading…" : "Load more") { Task { await search(reset: false) } }
                            .buttonStyle(.bordered)
                            .disabled(searching)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private func search(reset: Bool) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !searching, !text.isEmpty || selectedGenre != nil else { return }
        searching = true
        searchError = nil
        if reset { results = nil; nextPage = nil }
        var included: [[String: Any]] = []
        if let genre = selectedGenre { included.append(["id": genre.id, "label": genre.label]) }
        let request: [String: Any] = [
            "title": text,
            "includedTags": included,
            "excludedTags": [Any](),
            "parameters": [String: Any]()
        ]
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
