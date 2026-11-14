import SwiftUI

/// Details, the big Start/Continue button and the chapter list of one manga.
struct MangaScreen: View {
    let runtime: SourceRuntime
    let mangaId: String
    let fallbackTitle: String
    let fallbackCover: String?
    /// Open the reader as soon as the chapters are known (used by "Continue" on the Library screen).
    var autoContinue = false

    @EnvironmentObject private var library: LibraryStore

    @State private var info: MangaInfo?
    @State private var infoError: String?
    @State private var chapters: [Chapter]?          // in the source's order
    @State private var chaptersError: String?
    @State private var fromCache = false
    @State private var newestFirst = true
    @State private var expanded = false
    @State private var reading: ReaderStart?
    @State private var didAutoContinue = false

    /// What to open in the reader.
    struct ReaderStart: Identifiable {
        let index: Int
        let page: Int
        var id: String { "\(index)|\(page)" }
    }

    private var sourceId: String { runtime.sourceId }
    // Saved state of this title, reloaded when the library changes rather
    // than queried on every redraw.
    @State private var stored: StoredManga?
    @State private var progress: [String: ChapterProgress] = [:]
    private var title: String { info?.titles?.first ?? stored?.title ?? fallbackTitle }
    private var cover: String? {
        if let c = info?.image, !c.isEmpty { return c }
        if let c = fallbackCover, !c.isEmpty { return c }
        return stored?.cover
    }
    private var ordered: [Chapter] { ReadingOrder.ordered(chapters ?? []) }

    var body: some View {
        let saved = stored
        let readingOrder = ordered
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                header(saved, readingOrder: readingOrder, progress: progress)
                if let error = infoError, info == nil, saved == nil {
                    ErrorBox(message: error, runtime: runtime) { Task { await loadInfo() } }.padding(.horizontal, 20)
                }
                description(saved)
                chapterList(readingOrder, progress: progress)
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: library.revision) { _ in reload() }
        .task {
            if info == nil { await loadInfo() }
            if chapters == nil { await loadChapters() }
        }
        .fullScreenCover(item: $reading) { start in
            ReaderScreen(runtime: runtime, mangaId: mangaId, chapters: readingOrder, index: start.index, startPage: start.page)
                .environmentObject(library)
        }
    }

    private func reload() {
        stored = library.manga(sourceId: sourceId, mangaId: mangaId)
        progress = library.progress(sourceId: sourceId, mangaId: mangaId)
    }

    // MARK: Header (banner with cover art, title, tags, actions)

    private func header(_ saved: StoredManga?, readingOrder: [Chapter], progress: [String: ChapterProgress]) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { box in
                RemoteImage(runtime: runtime, url: cover, maxPixel: 700)
                    .frame(width: box.size.width, height: box.size.height)
            }
            .allowsHitTesting(false)
            LinearGradient(colors: [Theme.background.opacity(0.55), Theme.background.opacity(0.9), Theme.background],
                           startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 22) {
                RemoteImage(runtime: runtime, url: cover, maxPixel: 700)
                    .frame(width: 180, height: 270)
                    .clipShape(Theme.card(14))
                    .overlay(Theme.card(14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(Theme.serif(.largeTitle, weight: .bold))
                        .foregroundColor(Theme.text)
                        .lineLimit(3)
                    facts(saved, count: readingOrder.count)
                    tagPills(saved)
                    HStack(spacing: 12) {
                        continueButton(readingOrder, progress: progress, saved: saved)
                        libraryButton(saved)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .frame(height: 340)
    }

    private func facts(_ saved: StoredManga?, count: Int) -> some View {
        let author = info?.author ?? saved?.author ?? ""
        let status = info?.status ?? saved?.status ?? ""
        return HStack(spacing: 10) {
            if !status.isEmpty {
                Text(status.capitalized)
                    .font(.caption.weight(.bold)).foregroundColor(Theme.gold)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.gold.opacity(0.16)))
            }
            if !author.isEmpty {
                Label(author, systemImage: "person.fill").font(.subheadline).foregroundColor(Theme.text.opacity(0.8)).lineLimit(1)
            }
            if count > 0 {
                Label("\(count) chapters", systemImage: "book.fill").font(.subheadline).foregroundColor(Theme.text.opacity(0.8))
            }
        }
    }

    private func tagLabels(_ saved: StoredManga?) -> [String] {
        guard let info = info else { return saved?.tags ?? [] }
        var labels: [String] = []
        for section in info.tags ?? [] {
            for tag in section.tags ?? [] { labels.append(tag.label) }
        }
        return labels
    }

    @ViewBuilder
    private func tagPills(_ saved: StoredManga?) -> some View {
        let tags = tagLabels(saved)
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(tags.prefix(12).enumerated()), id: \.offset) { _, tag in
                        Text(tag)
                            .font(.caption.weight(.medium)).foregroundColor(Theme.text)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }
            }
            .accessibilityLabel("Genres: \(tags.joined(separator: ", "))")
        }
    }

    private func libraryButton(_ saved: StoredManga?) -> some View {
        let inLibrary = saved?.inLibrary ?? false
        return Button {
            if saved == nil {
                library.saveDetails(sourceId: sourceId, mangaId: mangaId, title: title, cover: cover, info: info)
            }
            library.setInLibrary(!inLibrary, sourceId: sourceId, mangaId: mangaId)
        } label: {
            Label(inLibrary ? "In library" : "Add to library", systemImage: inLibrary ? "bookmark.fill" : "bookmark")
                .font(Theme.heading(.subheadline))
                .foregroundColor(inLibrary ? Theme.accent : Theme.text)
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
                .background(Capsule().fill(inLibrary ? Theme.accentSoft : Color.white.opacity(0.1)))
        }
        .accessibilityHint(inLibrary ? "Removes this title from your library" : "Saves this title to your library")
    }

    @ViewBuilder
    private func continueButton(_ readingOrder: [Chapter], progress: [String: ChapterProgress], saved: StoredManga?) -> some View {
        if let target = ReadingOrder.continueTarget(ordered: readingOrder, progress: progress, lastChapterId: saved?.lastChapterId) {
            let chapter = readingOrder[target.index]
            Button {
                reading = ReaderStart(index: target.index, page: target.page)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(target.isStart ? "Start reading" : "Continue reading").font(Theme.heading(.subheadline))
                        Text(target.page > 0 ? "\(chapter.displayTitle) · page \(target.page + 1)" : chapter.displayTitle)
                            .font(.caption)
                            .lineLimit(1)
                            .opacity(0.9)
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .frame(minHeight: 52)
                .frame(maxWidth: 360, alignment: .leading)
                .background(Capsule().fill(Theme.accent))
            }
        } else if chapters == nil && chaptersError == nil {
            HStack(spacing: 10) { ProgressView(); Text("Loading chapters…").font(.subheadline) }
                .foregroundColor(Theme.muted)
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
        }
    }

    // MARK: Description

    @ViewBuilder
    private func description(_ saved: StoredManga?) -> some View {
        let text = info?.desc ?? saved?.description ?? ""
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(Theme.heading(.headline)).foregroundColor(Theme.text)
                Text(text)
                    .font(.callout)
                    .foregroundColor(Theme.muted)
                    .lineLimit(expanded ? nil : 4)
                if text.count > 280 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.footnote.weight(.semibold))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card().fill(Theme.surface))
            .padding(.horizontal, 20)
        }
    }

    // MARK: Chapters

    @ViewBuilder
    private func chapterList(_ readingOrder: [Chapter], progress: [String: ChapterProgress]) -> some View {
        if let error = chaptersError, chapters == nil {
            ErrorBox(message: error, runtime: runtime) { Task { await loadChapters() } }.padding(.horizontal, 20)
        } else if chapters != nil {
            SectionHeader(title: "Chapters", note: fromCache ? "Saved copy, the source could not be reached" : "\(readingOrder.count) in total") {
                HStack(spacing: 8) {
                    Button {
                        newestFirst.toggle()
                    } label: {
                        Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                            .font(.footnote.weight(.medium))
                            .foregroundColor(Theme.text)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background(Capsule().fill(Theme.raised))
                    }
                    Menu {
                        Button("Mark all as read") { mark(readingOrder, read: true) }
                        Button("Mark all as unread") { mark(readingOrder, read: false) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(Theme.text)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.raised))
                    }
                    .accessibilityLabel("More chapter actions")
                }
            }
            let indices = newestFirst ? Array(readingOrder.indices.reversed()) : Array(readingOrder.indices)
            ForEach(indices, id: \.self) { i in
                chapterRow(readingOrder, index: i, state: progress[readingOrder[i].id] ?? ChapterProgress())
                    .padding(.horizontal, 20)
            }
        }
    }

    private func number(_ chapter: Chapter, fallback: Int) -> String {
        guard let n = chapter.chapNum else { return "\(fallback)" }
        return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
    }

    private func chapterRow(_ readingOrder: [Chapter], index i: Int, state: ChapterProgress) -> some View {
        let chapter = readingOrder[i]
        let started = !state.read && state.lastPage > 0
        return Button {
            reading = ReaderStart(index: i, page: state.read ? 0 : state.lastPage)
        } label: {
            HStack(spacing: 14) {
                Text(number(chapter, fallback: i + 1))
                    .font(Theme.heading(.title3).monospacedDigit())
                    .foregroundColor(state.read ? Theme.muted.opacity(0.6) : Theme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 58, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.displayTitle)
                        .font(.body.weight(state.read ? .regular : .medium))
                        .foregroundColor(state.read ? Theme.muted : Theme.text)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        if let time = chapter.time { Text(String(time.prefix(10))) }
                        if started {
                            Text("Page \(state.lastPage + 1)\(state.pageCount > 0 ? " of \(state.pageCount)" : "")")
                                .foregroundColor(Theme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(Theme.muted)
                    if started && state.pageCount > 0 {
                        ProgressLine(fraction: Double(state.lastPage + 1) / Double(state.pageCount)).frame(maxWidth: 260)
                    }
                }
                Spacer()
                Image(systemName: state.read ? "checkmark" : "book.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundColor(state.read ? Theme.muted : .white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(state.read ? Theme.raised : Theme.accent))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.card(16).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapter.displayTitle), \(state.read ? "read" : started ? "started" : "unread")")
        .contextMenu {
            Button(state.read ? "Mark as unread" : "Mark as read") { mark([chapter], read: !state.read) }
            Button("Mark this and all earlier as read") { mark(Array(readingOrder[0...i]), read: true) }
        }
    }

    private func mark(_ list: [Chapter], read: Bool) {
        library.setRead(read, sourceId: sourceId, mangaId: mangaId, chapterIds: list.map { $0.id })
    }

    // MARK: Loading

    private func loadInfo() async {
        infoError = nil
        do {
            let loaded = try await runtime.call(SourceManga.self, "getMangaDetails", [mangaId]).mangaInfo
            info = loaded
            library.saveDetails(sourceId: sourceId, mangaId: mangaId,
                                title: loaded.titles?.first ?? fallbackTitle,
                                cover: (loaded.image?.isEmpty ?? true) ? fallbackCover : loaded.image, info: loaded)
        } catch {
            infoError = error.localizedDescription
        }
    }

    private func loadChapters() async {
        chaptersError = nil
        do {
            let loaded = try await runtime.call([Chapter].self, "getChapters", [mangaId])
            // The chapter rows hang off the manga row, so make sure it exists.
            if library.manga(sourceId: sourceId, mangaId: mangaId) == nil {
                library.saveDetails(sourceId: sourceId, mangaId: mangaId, title: title, cover: cover, info: info)
            }
            library.saveChapters(sourceId: sourceId, mangaId: mangaId, chapters: loaded)
            chapters = loaded
            fromCache = false
        } catch {
            // Offline or the source is down: fall back to what was saved last time.
            let cached = library.cachedChapters(sourceId: sourceId, mangaId: mangaId)
            if cached.isEmpty {
                chaptersError = error.localizedDescription
            } else {
                chapters = cached
                fromCache = true
            }
        }
        openReaderIfAsked()
    }

    /// "Continue" on the Library screen lands here and goes straight into the reader.
    private func openReaderIfAsked() {
        guard autoContinue, !didAutoContinue, reading == nil else { return }
        didAutoContinue = true
        let order = ordered
        let saved = library.manga(sourceId: sourceId, mangaId: mangaId)
        let progress = library.progress(sourceId: sourceId, mangaId: mangaId)
        if let target = ReadingOrder.continueTarget(ordered: order, progress: progress, lastChapterId: saved?.lastChapterId) {
            reading = ReaderStart(index: target.index, page: target.page)
        }
    }
}
