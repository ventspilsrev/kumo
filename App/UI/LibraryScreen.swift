import SwiftUI

/// Home of the app: a banner to continue the last title, a few numbers,
/// recent history, then the saved library as a cover grid.
struct LibraryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var store: SourceStore
    @EnvironmentObject private var app: AppState
    @State private var onlyUnread = false
    // Loaded from the database when the screen appears or the library changes,
    // not on every redraw.
    @State private var history: [StoredManga] = []
    @State private var all: [StoredManga] = []
    @State private var numbers: (titles: Int, chaptersRead: Int, unread: Int) = (0, 0, 0)
    @State private var lastRead: (name: String, page: Int, pageCount: Int)?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 18, alignment: .top)]

    var body: some View {
        let shown = onlyUnread ? all.filter { $0.unread > 0 } : all
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if let problem = library.databaseProblem {
                    ErrorBox(message: problem).padding(.horizontal, 20)
                }
                if let latest = history.first {
                    continueBanner(latest)
                }
                statTiles(numbers)
                if history.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Jump back in", note: "Titles you opened recently")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(history.dropFirst()) { manga in
                                    link(manga, autoContinue: true) {
                                        HistoryCell(runtime: store.runtime(for: manga.sourceId), manga: manga)
                                    }
                                    .contextMenu {
                                        Button("Remove from history") {
                                            library.removeFromHistory(sourceId: manga.sourceId, mangaId: manga.mangaId)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
                libraryGrid(all: all, shown: shown)
            }
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Kumo")
        .onAppear(perform: reload)
        .onChange(of: library.revision) { _ in reload() }
    }

    private func reload() {
        history = library.history(limit: 12)
        all = library.library()
        numbers = library.stats()
        lastRead = history.first.flatMap { library.lastRead($0) }
    }

    // MARK: Banner

    @ViewBuilder
    private func continueBanner(_ manga: StoredManga) -> some View {
        let last = lastRead
        let fraction = manga.total > 0 ? Double(manga.total - manga.unread) / Double(manga.total) : 0
        let detail: String = {
            guard let last = last else { return "Pick up where you stopped" }
            return last.page > 0 ? "\(last.name) · page \(last.page + 1)" : last.name
        }()
        link(manga, autoContinue: true) {
            HeroBanner(runtime: store.runtime(for: manga.sourceId), cover: manga.cover, eyebrow: "CONTINUE READING",
                       title: manga.title, detail: detail, button: "Continue reading") {
                if manga.total > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressLine(fraction: fraction).frame(maxWidth: 320)
                        Text("\(manga.total - manga.unread) of \(manga.total) chapters read")
                            .font(.caption).foregroundColor(Theme.text.opacity(0.7))
                    }
                }
            }
        }
        .contextMenu {
            Button("Remove from history") {
                library.removeFromHistory(sourceId: manga.sourceId, mangaId: manga.mangaId)
            }
        }
        .accessibilityLabel("Continue reading \(manga.title). \(detail)")
    }

    // MARK: Numbers

    private func statTiles(_ numbers: (titles: Int, chaptersRead: Int, unread: Int)) -> some View {
        HStack(spacing: 14) {
            tile("\(numbers.titles)", "in your library", "books.vertical.fill")
            tile("\(numbers.chaptersRead)", "chapters read", "checkmark.circle.fill")
            tile("\(numbers.unread)", "chapters waiting", "bookmark.fill")
        }
        .padding(.horizontal, 20)
    }

    private func tile(_ value: String, _ label: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(Theme.heading(.title2)).foregroundColor(Theme.text)
                Text(label).font(.caption).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.card().fill(Theme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: Library grid

    @ViewBuilder
    private func libraryGrid(all: [StoredManga], shown: [StoredManga]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Library", note: all.isEmpty ? nil : "\(all.count) saved")
            if all.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your shelf is empty").font(Theme.heading(.title3)).foregroundColor(Theme.text)
                    Text("Open Browse, pick a title and tap “Add to library”. It will show up here with its unread count.")
                        .font(.callout).foregroundColor(Theme.muted)
                    Button { app.tab = 1 } label: { PrimaryLabel(text: "Browse manga", symbol: "safari") }
                        .padding(.top, 4)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card().fill(Theme.surface))
                .padding(.horizontal, 20)
            } else {
                HStack(spacing: 10) {
                    Button { onlyUnread = false } label: { Chip(text: "All", selected: !onlyUnread) }
                    Button { onlyUnread = true } label: { Chip(text: "Unread", selected: onlyUnread) }
                }
                .padding(.horizontal, 20)
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(shown) { manga in
                        link(manga, autoContinue: false) {
                            LibraryCell(runtime: store.runtime(for: manga.sourceId), manga: manga)
                        }
                        .contextMenu {
                            Button("Remove from library", role: .destructive) {
                                library.setInLibrary(false, sourceId: manga.sourceId, mangaId: manga.mangaId)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                if shown.isEmpty {
                    Text("Nothing unread. You are caught up.")
                        .font(.callout).foregroundColor(Theme.muted).padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder
    private func link<Label: View>(_ manga: StoredManga, autoContinue: Bool, @ViewBuilder label: () -> Label) -> some View {
        if store.installed.contains(where: { $0.id == manga.sourceId }) {
            NavigationLink(destination: MangaScreen(runtime: store.runtime(for: manga.sourceId), mangaId: manga.mangaId,
                                                    fallbackTitle: manga.title, fallbackCover: manga.cover,
                                                    autoContinue: autoContinue)) {
                label()
            }
            .buttonStyle(.plain)
        } else {
            // The source was removed. Show the entry, but it cannot be opened.
            label().opacity(0.4).accessibilityHint("The source for this title is not installed")
        }
    }
}

/// Library cover with unread count.
struct LibraryCell: View {
    let runtime: SourceRuntime
    let manga: StoredManga

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(runtime: runtime, url: manga.cover)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(Theme.card(Theme.coverRadius))
                .overlay(alignment: .topTrailing) {
                    if manga.unread > 0 { Seal(text: "\(manga.unread)").padding(8) }
                }
            Text(manga.title).font(.footnote.weight(.medium)).lineLimit(2).foregroundColor(Theme.text)
            Text(manga.unread > 0 ? "\(manga.unread) chapters unread" : (manga.total > 0 ? "All read" : " "))
                .font(.caption2).foregroundColor(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(manga.title), \(manga.unread) chapters unread")
    }
}

/// Card for the "Jump back in" row.
struct HistoryCell: View {
    let runtime: SourceRuntime
    let manga: StoredManga

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(runtime: runtime, url: manga.cover)
                .frame(width: 76, height: 114)
                .clipShape(Theme.card(10))
            VStack(alignment: .leading, spacing: 6) {
                Text(manga.title).font(Theme.heading(.subheadline)).lineLimit(2).foregroundColor(Theme.text)
                    .multilineTextAlignment(.leading)
                Text(manga.total > 0 ? "\(manga.total - manga.unread) of \(manga.total) chapters read" : "Started")
                    .font(.caption).foregroundColor(Theme.muted)
                if manga.total > 0 {
                    ProgressLine(fraction: Double(manga.total - manga.unread) / Double(manga.total))
                }
                Spacer(minLength: 0)
                Label("Continue", systemImage: "play.fill").font(.caption.weight(.bold)).foregroundColor(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 330, height: 138, alignment: .leading)
        .background(Theme.card().fill(Theme.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Continue \(manga.title)")
    }
}
