import SwiftUI

/// Home of the app: continue reading, then the saved library as a cover grid.
struct LibraryScreen: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var store: SourceStore
    @State private var onlyUnread = false

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16, alignment: .top)]

    var body: some View {
        _ = library.revision
        let history = library.history(limit: 12)
        let all = library.library()
        let shown = onlyUnread ? all.filter { $0.unread > 0 } : all
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let problem = library.databaseProblem {
                    ErrorBox(message: problem)
                }
                if !history.isEmpty {
                    section("Continue reading") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(history) { manga in
                                    link(manga) { HistoryCell(runtime: store.runtime(for: manga.sourceId), manga: manga) }
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
                section("Library") {
                    if all.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your shelf is empty.")
                                .font(Theme.serif(.title3)).foregroundColor(Theme.text)
                            Text("Open the Browse tab, pick a title and tap “Add to library”. It will appear here with its unread count.")
                                .font(.callout).foregroundColor(Theme.muted)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    } else {
                        HStack(spacing: 8) {
                            Button { onlyUnread = false } label: { Chip(text: "All \(all.count)", selected: !onlyUnread) }
                            Button { onlyUnread = true } label: { Chip(text: "Unread", selected: onlyUnread) }
                        }
                        .padding(.horizontal, 20)
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(shown) { manga in
                                link(manga) { LibraryCell(runtime: store.runtime(for: manga.sourceId), manga: manga) }
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
            .padding(.vertical, 16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Kumo")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.serif(.title2, weight: .semibold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 20)
            content()
        }
    }

    @ViewBuilder
    private func link<Label: View>(_ manga: StoredManga, @ViewBuilder label: () -> Label) -> some View {
        if store.installed.contains(where: { $0.id == manga.sourceId }) {
            NavigationLink(destination: MangaScreen(runtime: store.runtime(for: manga.sourceId), mangaId: manga.mangaId,
                                                    fallbackTitle: manga.title, fallbackCover: manga.cover)) {
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
        VStack(alignment: .leading, spacing: 5) {
            RemoteImage(runtime: runtime, url: manga.cover)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if manga.unread > 0 { Seal(text: "\(manga.unread)").padding(6) }
                }
            Text(manga.title).font(.footnote).lineLimit(2).foregroundColor(Theme.text)
            Text(manga.unread > 0 ? "\(manga.unread) unread" : (manga.total > 0 ? "Read" : " "))
                .font(.caption2).foregroundColor(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(manga.title), \(manga.unread) unread")
    }
}

/// Wider card for the "Continue reading" row.
struct HistoryCell: View {
    let runtime: SourceRuntime
    let manga: StoredManga

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(runtime: runtime, url: manga.cover)
                .frame(width: 70, height: 105)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(manga.title).font(Theme.serif(.headline)).lineLimit(2).foregroundColor(Theme.text)
                Text(manga.total > 0 ? "\(manga.total - manga.unread) of \(manga.total) read" : "Started")
                    .font(.caption).foregroundColor(Theme.muted)
                Spacer(minLength: 0)
                Label("Continue", systemImage: "play.fill").font(.caption.weight(.semibold)).foregroundColor(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 280, height: 125, alignment: .leading)
        .background(Theme.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Continue \(manga.title)")
    }
}
