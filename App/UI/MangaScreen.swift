import SwiftUI

/// Details, the big Start/Continue button and the chapter list of one manga.
struct MangaScreen: View {
    let runtime: SourceRuntime
    let mangaId: String
    let fallbackTitle: String
    let fallbackCover: String?

    @EnvironmentObject private var library: LibraryStore

    @State private var info: MangaInfo?
    @State private var infoError: String?
    @State private var chapters: [Chapter]?          // in the source's order
    @State private var chaptersError: String?
    @State private var fromCache = false
    @State private var newestFirst = true
    @State private var expanded = false
    @State private var reading: ReaderStart?

    /// What to open in the reader.
    struct ReaderStart: Identifiable {
        let index: Int
        let page: Int
        var id: String { "\(index)|\(page)" }
    }

    private var sourceId: String { runtime.sourceId }
    private var stored: StoredManga? {
        _ = library.revision
        return library.manga(sourceId: sourceId, mangaId: mangaId)
    }
    private var title: String { info?.titles?.first ?? stored?.title ?? fallbackTitle }
    private var cover: String? {
        if let c = info?.image, !c.isEmpty { return c }
        if let c = fallbackCover, !c.isEmpty { return c }
        return stored?.cover
    }
    private var ordered: [Chapter] { ReadingOrder.ordered(chapters ?? []) }

    var body: some View {
        let saved = stored
        let progress = library.progress(sourceId: sourceId, mangaId: mangaId)
        let readingOrder = ordered
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                header(saved)
                continueButton(readingOrder, progress: progress, saved: saved)
                if let error = infoError, info == nil, saved == nil {
                    ErrorBox(message: error) { Task { await loadInfo() } }
                }
                description(saved)
                Rectangle().fill(Theme.line).frame(height: 1)
                chapterList(readingOrder, progress: progress)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if info == nil { await loadInfo() }
            if chapters == nil { await loadChapters() }
        }
        .fullScreenCover(item: $reading) { start in
            ReaderScreen(runtime: runtime, mangaId: mangaId, chapters: readingOrder, index: start.index, startPage: start.page)
                .environmentObject(library)
        }
    }

    // MARK: Header

    private func header(_ saved: StoredManga?) -> some View {
        HStack(alignment: .top, spacing: 18) {
            RemoteImage(runtime: runtime, url: cover, maxPixel: 600)
                .frame(width: 160, height: 240)
                .clipped()
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.serif(.title, weight: .semibold)).foregroundColor(Theme.text)
                let author = info?.author ?? saved?.author ?? ""
                if !author.isEmpty { Text(author).font(.subheadline).foregroundColor(Theme.muted) }
                let status = info?.status ?? saved?.status ?? ""
                if !status.isEmpty { Text(status.capitalized).font(.subheadline).foregroundColor(Theme.muted) }
                let tags = tagLabels(saved)
                if !tags.isEmpty {
                    Text(tags.joined(separator: " · ")).font(.footnote).foregroundColor(Theme.muted)
                }
                Spacer(minLength: 4)
                libraryButton(saved)
            }
            Spacer(minLength: 0)
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

    private func libraryButton(_ saved: StoredManga?) -> some View {
        let inLibrary = saved?.inLibrary ?? false
        return Button {
            if saved == nil {
                library.saveDetails(sourceId: sourceId, mangaId: mangaId, title: title, cover: cover, info: info)
            }
            library.setInLibrary(!inLibrary, sourceId: sourceId, mangaId: mangaId)
        } label: {
            Label(inLibrary ? "In library" : "Add to library", systemImage: inLibrary ? "bookmark.fill" : "bookmark")
                .font(.subheadline.weight(.medium))
                .foregroundColor(inLibrary ? Theme.accent : Theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .overlay(Rectangle().stroke(inLibrary ? Theme.accent : Theme.line, lineWidth: 1))
        }
        .accessibilityHint(inLibrary ? "Removes this title from your library" : "Saves this title to your library")
    }

    // MARK: Continue

    @ViewBuilder
    private func continueButton(_ readingOrder: [Chapter], progress: [String: ChapterProgress], saved: StoredManga?) -> some View {
        if let target = ReadingOrder.continueTarget(ordered: readingOrder, progress: progress, lastChapterId: saved?.lastChapterId) {
            let chapter = readingOrder[target.index]
            Button {
                reading = ReaderStart(index: target.index, page: target.page)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.isStart ? "Start reading" : "Continue reading").font(.headline)
                        Text(target.page > 0 ? "\(chapter.displayTitle) · page \(target.page + 1)" : chapter.displayTitle)
                            .font(.footnote)
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Theme.accent)
            }
        }
    }

    // MARK: Description

    @ViewBuilder
    private func description(_ saved: StoredManga?) -> some View {
        let text = info?.desc ?? saved?.description ?? ""
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.callout)
                    .foregroundColor(Theme.muted)
                    .lineLimit(expanded ? nil : 4)
                if text.count > 280 {
                    Button(expanded ? "Show less" : "Show more") { expanded.toggle() }.font(.footnote)
                }
            }
        }
    }

    // MARK: Chapters

    @ViewBuilder
    private func chapterList(_ readingOrder: [Chapter], progress: [String: ChapterProgress]) -> some View {
        if let error = chaptersError, chapters == nil {
            ErrorBox(message: error) { Task { await loadChapters() } }
        } else if chapters != nil {
            HStack {
                Text("\(readingOrder.count) chapters").font(Theme.serif(.title3, weight: .semibold)).foregroundColor(Theme.text)
                if fromCache {
                    Text("saved copy").font(.caption).foregroundColor(Theme.muted)
                        .accessibilityLabel("Showing the saved copy because the source could not be reached")
                }
                Spacer()
                Button {
                    newestFirst.toggle()
                } label: {
                    Label(newestFirst ? "Newest first" : "Oldest first", systemImage: "arrow.up.arrow.down")
                        .font(.footnote)
                        .frame(minHeight: 44)
                }
                Menu {
                    Button("Mark all as read") { mark(readingOrder, read: true) }
                    Button("Mark all as unread") { mark(readingOrder, read: false) }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("More chapter actions")
            }
            let indices = newestFirst ? Array(readingOrder.indices.reversed()) : Array(readingOrder.indices)
            ForEach(indices, id: \.self) { i in
                chapterRow(readingOrder, index: i, state: progress[readingOrder[i].id] ?? ChapterProgress())
            }
        } else {
            HStack { Spacer(); ProgressView("Loading chapters…"); Spacer() }.padding(24)
        }
    }

    private func chapterRow(_ readingOrder: [Chapter], index i: Int, state: ChapterProgress) -> some View {
        let chapter = readingOrder[i]
        let started = !state.read && state.lastPage > 0
        return VStack(spacing: 0) {
            Button {
                reading = ReaderStart(index: i, page: state.read ? 0 : state.lastPage)
            } label: {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(state.read ? Color.clear : Theme.accent)
                        .frame(width: 3, height: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.displayTitle)
                            .foregroundColor(state.read ? Theme.muted : Theme.text)
                            .multilineTextAlignment(.leading)
                        if started {
                            Text("Page \(state.lastPage + 1)\(state.pageCount > 0 ? " of \(state.pageCount)" : "")")
                                .font(.caption)
                                .foregroundColor(Theme.accent)
                        }
                    }
                    Spacer()
                    if let time = chapter.time {
                        Text(String(time.prefix(10))).font(.caption).foregroundColor(Theme.muted)
                    }
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(chapter.displayTitle), \(state.read ? "read" : started ? "started" : "unread")")
            .contextMenu {
                Button(state.read ? "Mark as unread" : "Mark as read") { mark([chapter], read: !state.read) }
                Button("Mark this and all earlier as read") { mark(Array(readingOrder[0...i]), read: true) }
            }
            Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
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
    }
}
