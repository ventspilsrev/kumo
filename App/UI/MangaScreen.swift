import SwiftUI

/// Details and chapter list for one manga.
struct MangaScreen: View {
    let runtime: SourceRuntime
    let mangaId: String
    let fallbackTitle: String
    let fallbackCover: String?

    @State private var info: MangaInfo?
    @State private var infoError: String?
    @State private var chapters: [Chapter]?
    @State private var chaptersError: String?
    @State private var reading: Chapter?

    private var title: String { info?.titles?.first ?? fallbackTitle }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                if let error = infoError {
                    ErrorBox(message: error) { Task { await loadInfo() } }
                }
                if let desc = info?.desc, !desc.isEmpty {
                    Text(desc).font(.callout).foregroundColor(.secondary)
                }
                Divider()
                chapterList
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if info == nil { await loadInfo() }
            if chapters == nil { await loadChapters() }
        }
        .fullScreenCover(item: $reading) { chapter in
            ReaderScreen(runtime: runtime, mangaId: mangaId, chapter: chapter)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(runtime: runtime, url: info?.image ?? fallbackCover, maxPixel: 600)
                .frame(width: 150, height: 225)
                .clipped()
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                if let author = info?.author, !author.isEmpty {
                    Text(author).font(.subheadline).foregroundColor(.secondary)
                }
                if let status = info?.status, !status.isEmpty {
                    Text(status.capitalized).font(.subheadline).foregroundColor(.secondary)
                }
                let tags = (info?.tags ?? []).flatMap { $0.tags ?? [] }.map { $0.label }
                if !tags.isEmpty {
                    Text(tags.joined(separator: " · ")).font(.footnote).foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        if let error = chaptersError {
            ErrorBox(message: error) { Task { await loadChapters() } }
        } else if let chapters = chapters {
            Text("\(chapters.count) chapters").font(.headline)
            ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                Button {
                    reading = chapter
                } label: {
                    HStack {
                        Text(chapter.displayTitle).foregroundColor(.primary).multilineTextAlignment(.leading)
                        Spacer()
                        if let time = chapter.time { Text(String(time.prefix(10))).font(.caption).foregroundColor(.secondary) }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        } else {
            HStack { Spacer(); ProgressView("Loading chapters…"); Spacer() }.padding(24)
        }
    }

    private func loadInfo() async {
        infoError = nil
        do {
            info = try await runtime.call(SourceManga.self, "getMangaDetails", [mangaId]).mangaInfo
        } catch {
            infoError = error.localizedDescription
        }
    }

    private func loadChapters() async {
        chaptersError = nil
        do {
            chapters = try await runtime.call([Chapter].self, "getChapters", [mangaId])
        } catch {
            chaptersError = error.localizedDescription
        }
    }
}
