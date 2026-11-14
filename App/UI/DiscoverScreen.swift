import SwiftUI

/// Loads and keeps what the Browse tab shows for one source.
@MainActor
final class DiscoverModel: ObservableObject {
    @Published var sections: [HomeSection] = []
    @Published var homeLoading = false
    @Published var homeError: String?
    @Published var tagSections: [TagSection] = []
    @Published var supportsExclusion = false
    @Published var suggestions: [SuggestionRow] = []
    @Published var suggestionsLoading = false

    private var loadedFor: String?
    private var generation = 0

    func load(source: InstalledSource, runtime: SourceRuntime, library: LibraryStore, force: Bool = false) async {
        if loadedFor == source.id && !force { return }
        loadedFor = source.id
        generation += 1
        let mine = generation
        sections = []
        tagSections = []
        suggestions = []
        supportsExclusion = false
        homeError = nil
        homeLoading = true

        // 1. The source's own home page.
        let collected = SectionCollector()
        do {
            _ = try await runtime.callRaw("getHomePageSections", [], onSection: { data in
                if let section = try? JSONDecoder().decode(HomeSection.self, from: data) { collected.add(section) }
            })
            guard mine == generation else { return }
            sections = DiscoverModel.fillMissingCovers(collected.all().filter { !($0.items ?? []).isEmpty })
            if sections.isEmpty { homeError = "The source returned an empty home page." }
        } catch {
            guard mine == generation else { return }
            homeError = error.localizedDescription
        }
        homeLoading = false

        // 2. Filters this source offers.
        if let tags = try? await runtime.call([TagSection].self, "getSearchTags", []) {
            guard mine == generation else { return }
            tagSections = tags.filter { !($0.tags ?? []).isEmpty }
        }
        if let exclusion = try? await runtime.call(Bool.self, "supportsTagExclusion", []) {
            guard mine == generation else { return }
            supportsExclusion = exclusion
        }

        // 3. Suggestions from the reader's own library and history.
        let taste = library.tasteTitles()
        let ownIds = Set(taste.filter { $0.sourceId == source.id }.map { $0.mangaId })
        let ownTitles = Set(taste.map { Suggestions.normalize($0.title) })
        suggestionsLoading = true
        for pick in Suggestions.picks(taste: taste, genres: genreTags) {
            let request: [String: Any] = [
                "title": "",
                "includedTags": [["id": pick.tag.id, "label": pick.tag.label]],
                "excludedTags": [Any](),
                "parameters": [String: Any]()
            ]
            guard let page = try? await runtime.call(PagedResults.self, "getSearchResults", [request, NSNull()]) else { continue }
            guard mine == generation else { return }
            let fresh = (page.results ?? []).filter {
                !ownIds.contains($0.mangaId) && !ownTitles.contains(Suggestions.normalize($0.title))
            }
            if !fresh.isEmpty {
                suggestions.append(SuggestionRow(tag: pick.tag, reason: pick.reason, items: Array(fresh.prefix(20))))
            }
        }
        suggestionsLoading = false
    }

    /// Tags that are genres (as opposed to sort order, status and so on).
    var genreTags: [Tag] {
        let genreSections = tagSections.filter { ($0.label + $0.id).lowercased().contains("genre") }
        return (genreSections.isEmpty ? tagSections : genreSections).flatMap { $0.tags ?? [] }
    }

    /// Some sources return a row without cover addresses (their site
    /// changed). Reuse a cover seen for the same title in another row.
    private static func fillMissingCovers(_ input: [HomeSection]) -> [HomeSection] {
        var loaded = input
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
        return loaded
    }
}

/// The Browse tab: suggestions, the source's rows, search and filters, for
/// the sources that are installed. Managing sources lives in Settings.
struct DiscoverScreen: View {
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var app: AppState
    @StateObject private var model = DiscoverModel()
    @AppStorage("browse.source") private var savedSourceId = ""

    @State private var query = ""
    @State private var included: [Tag] = []
    @State private var excluded: [Tag] = []
    @State private var showFilters = false
    @State private var results: [PartialManga]?
    @State private var nextPage: JSONValue?
    @State private var searching = false
    @State private var searchError: String?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16, alignment: .top)]

    private var source: InstalledSource? {
        store.installed.first(where: { $0.id == savedSourceId }) ?? store.installed.first
    }
    private var hasFilters: Bool { !included.isEmpty || !excluded.isEmpty }
    private var showingResults: Bool { results != nil || searching || searchError != nil }

    var body: some View {
        Group {
            if let source = source {
                content(source, runtime: store.runtime(for: source.id))
            } else {
                noSources
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Browse")
    }

    private var noSources: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundColor(Theme.muted)
            Text("No sources installed").font(Theme.serif(.title2, weight: .semibold)).foregroundColor(Theme.text)
            Text("Kumo ships without sources. Add a repository and install a source, then manga from it shows up here.")
                .font(.callout).foregroundColor(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
            Button { app.tab = 2 } label: {
                Text("Open Settings").font(.headline).foregroundColor(.white)
                    .padding(.horizontal, 24).frame(minHeight: 48).background(Theme.accent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ source: InstalledSource, runtime: SourceRuntime) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                controls(source)
                if showingResults {
                    resultsView(runtime)
                } else {
                    spotlight(runtime)
                    suggestionRows(runtime)
                    homeRows(runtime)
                }
            }
            .padding(.vertical, 14)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(source.name)")
        .onSubmit(of: .search) { Task { await search(runtime, reset: true) } }
        .onChange(of: query) { text in
            if text.isEmpty && !hasFilters { clearResults() }
        }
        .task(id: source.id) {
            await model.load(source: source, runtime: runtime, library: library)
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet(sections: model.tagSections, supportsExclusion: model.supportsExclusion,
                        included: included, excluded: excluded) { newIncluded, newExcluded in
                included = newIncluded
                excluded = newExcluded
                if hasFilters || !query.isEmpty {
                    Task { await search(runtime, reset: true) }
                } else {
                    clearResults()
                }
            }
        }
    }

    // MARK: Controls (source picker, filter button, active filters)

    private func controls(_ source: InstalledSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if store.installed.count > 1 {
                    Menu {
                        ForEach(store.installed) { other in
                            Button(other.name) { switchSource(to: other.id) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(source.name).font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .foregroundColor(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
                    }
                    .accessibilityLabel("Source: \(source.name). Tap to change")
                } else {
                    Text(source.name).font(.subheadline).foregroundColor(Theme.muted)
                }
                Spacer()
                Button { showFilters = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                        Text(hasFilters ? "Filters · \(included.count + excluded.count)" : "Filters")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(hasFilters ? .white : Theme.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(hasFilters ? Theme.accent : Color.clear)
                    .overlay(Rectangle().stroke(hasFilters ? Theme.accent : Theme.line, lineWidth: 1))
                }
                .disabled(model.tagSections.isEmpty)
                .opacity(model.tagSections.isEmpty ? 0.4 : 1)
                .accessibilityLabel("Filters and genres")
            }
            if hasFilters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(included.enumerated()), id: \.offset) { _, tag in
                            Chip(text: tag.label, selected: true)
                        }
                        ForEach(Array(excluded.enumerated()), id: \.offset) { _, tag in
                            Text("Not \(tag.label)")
                                .font(.footnote).foregroundColor(Theme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .overlay(Rectangle().stroke(Theme.accent, lineWidth: 1))
                        }
                        Button("Clear") {
                            included = []
                            excluded = []
                            if query.isEmpty { clearResults() } else { Task { await search(store.runtime(for: source.id), reset: true) } }
                        }
                        .font(.footnote)
                        .padding(.horizontal, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func switchSource(to id: String) {
        savedSourceId = id
        query = ""
        included = []
        excluded = []
        clearResults()
    }

    private func clearResults() {
        results = nil
        searchError = nil
        nextPage = nil
    }

    // MARK: Rows

    private func link(_ manga: PartialManga, _ runtime: SourceRuntime, width: CGFloat = 130) -> some View {
        NavigationLink(destination: MangaScreen(runtime: runtime, mangaId: manga.mangaId, fallbackTitle: manga.title, fallbackCover: manga.image)) {
            MangaCell(runtime: runtime, manga: manga, width: width)
        }
        .buttonStyle(.plain)
    }

    private func header(_ title: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.accent).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(title).font(Theme.serif(.title2, weight: .semibold)).foregroundColor(Theme.text)
            }
            if let note = note {
                Text(note).font(.footnote).foregroundColor(Theme.muted).padding(.leading, 20)
            }
        }
        .padding(.horizontal, 20)
    }

    private func row(_ items: [PartialManga], _ runtime: SourceRuntime) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, manga in link(manga, runtime) }
            }
            .padding(.horizontal, 20)
        }
    }

    /// One large pick at the top of the page.
    @ViewBuilder
    private func spotlight(_ runtime: SourceRuntime) -> some View {
        if let first = model.suggestions.first, let manga = first.items.first {
            NavigationLink(destination: MangaScreen(runtime: runtime, mangaId: manga.mangaId, fallbackTitle: manga.title, fallbackCover: manga.image)) {
                HStack(alignment: .top, spacing: 20) {
                    RemoteImage(runtime: runtime, url: manga.image, maxPixel: 600)
                        .frame(width: 150, height: 225)
                        .clipped()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SUGGESTED FOR YOU").font(.caption.weight(.semibold)).foregroundColor(Theme.accent)
                        Text(manga.title).font(Theme.serif(.title, weight: .semibold)).foregroundColor(Theme.text)
                            .multilineTextAlignment(.leading).lineLimit(3)
                        Text("\(first.reason) · \(first.tag.label)").font(.callout).foregroundColor(Theme.muted)
                            .multilineTextAlignment(.leading)
                        if let subtitle = manga.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.footnote).foregroundColor(Theme.muted)
                        }
                        Spacer(minLength: 0)
                        Text("View").font(.subheadline.weight(.semibold)).foregroundColor(.white)
                            .padding(.horizontal, 22).frame(minHeight: 40).background(Theme.accent)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .overlay(Rectangle().stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .accessibilityLabel("Suggested for you: \(manga.title). \(first.reason)")
        }
    }

    @ViewBuilder
    private func suggestionRows(_ runtime: SourceRuntime) -> some View {
        ForEach(model.suggestions) { suggestion in
            VStack(alignment: .leading, spacing: 10) {
                header("More \(suggestion.tag.label)", note: suggestion.reason)
                row(suggestion.items, runtime)
            }
        }
        if model.suggestionsLoading && model.suggestions.isEmpty && !model.homeLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding suggestions…").font(.footnote).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func homeRows(_ runtime: SourceRuntime) -> some View {
        if model.homeLoading && model.sections.isEmpty {
            HStack { Spacer(); ProgressView("Loading…"); Spacer() }.padding(40)
        } else if let error = model.homeError, model.sections.isEmpty {
            HStack {
                Spacer()
                ErrorBox(message: error) {
                    if let source = source {
                        Task { await model.load(source: source, runtime: runtime, library: library, force: true) }
                    }
                }
                Spacer()
            }
        } else {
            ForEach(Array(model.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 10) {
                    header(section.title)
                    row(section.items ?? [], runtime)
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder
    private func resultsView(_ runtime: SourceRuntime) -> some View {
        if let error = searchError, (results ?? []).isEmpty {
            HStack { Spacer(); ErrorBox(message: error) { Task { await search(runtime, reset: true) } }; Spacer() }
        } else if searching && results == nil {
            HStack { Spacer(); ProgressView("Loading…"); Spacer() }.padding(40)
        } else if let results = results {
            if results.isEmpty {
                Text("Nothing found. Try fewer filters.").foregroundColor(Theme.muted).padding(40)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, manga in link(manga, runtime) }
                }
                .padding(.horizontal, 20)
                if nextPage != nil {
                    HStack {
                        Spacer()
                        Button(searching ? "Loading…" : "Load more") { Task { await search(runtime, reset: false) } }
                            .buttonStyle(.bordered)
                            .disabled(searching)
                        Spacer()
                    }
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private func search(_ runtime: SourceRuntime, reset: Bool) async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !searching, !text.isEmpty || hasFilters else { return }
        searching = true
        searchError = nil
        if reset { results = nil; nextPage = nil }
        let request: [String: Any] = [
            "title": text,
            "includedTags": included.map { ["id": $0.id, "label": $0.label] },
            "excludedTags": excluded.map { ["id": $0.id, "label": $0.label] },
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

/// The filter page: every tag the source offers, grouped, each one
/// off / included / excluded.
struct FilterSheet: View {
    let sections: [TagSection]
    let supportsExclusion: Bool
    let onApply: ([Tag], [Tag]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var included: [String: Tag]
    @State private var excluded: [String: Tag]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 10)]

    init(sections: [TagSection], supportsExclusion: Bool, included: [Tag], excluded: [Tag],
         onApply: @escaping ([Tag], [Tag]) -> Void) {
        self.sections = sections
        self.supportsExclusion = supportsExclusion
        self.onApply = onApply
        _included = State(initialValue: Dictionary(included.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        _excluded = State(initialValue: Dictionary(excluded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    Text(supportsExclusion
                         ? "Tap once to include a tag, twice to exclude it, a third time to clear it."
                         : "Tap a tag to include it. This source cannot exclude tags.")
                        .font(.callout).foregroundColor(Theme.muted)
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.label.capitalized)
                                .font(Theme.serif(.title3, weight: .semibold)).foregroundColor(Theme.text)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                ForEach(Array((section.tags ?? []).enumerated()), id: \.offset) { _, tag in
                                    tagButton(tag)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reset") { included = [:]; excluded = [:] }
                        .disabled(included.isEmpty && excluded.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onApply(Array(included.values), Array(excluded.values))
                    dismiss()
                } label: {
                    Text(included.isEmpty && excluded.isEmpty ? "Show everything" : "Show results · \(included.count + excluded.count) selected")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(Theme.accent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Theme.background)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func tagButton(_ tag: Tag) -> some View {
        let isIncluded = included[tag.id] != nil
        let isExcluded = excluded[tag.id] != nil
        return Button {
            if isIncluded {
                included[tag.id] = nil
                if supportsExclusion { excluded[tag.id] = tag }
            } else if isExcluded {
                excluded[tag.id] = nil
            } else {
                included[tag.id] = tag
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isIncluded ? "checkmark" : isExcluded ? "minus" : "circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(isIncluded ? Theme.background : isExcluded ? Theme.accent : Theme.line)
                Text(tag.label)
                    .font(.subheadline)
                    .foregroundColor(isIncluded ? Theme.background : isExcluded ? Theme.accent : Theme.text)
                    .lineLimit(1)
                    .strikethrough(isExcluded)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isIncluded ? Theme.text : Color.clear)
            .overlay(Rectangle().stroke(isIncluded ? Theme.text : isExcluded ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .accessibilityLabel("\(tag.label), \(isIncluded ? "included" : isExcluded ? "excluded" : "off")")
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
