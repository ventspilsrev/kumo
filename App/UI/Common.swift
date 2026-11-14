import SwiftUI

/// An image loaded through a source (covers). Shows a neutral box while
/// loading and a small icon if it fails.
struct RemoteImage: View {
    let runtime: SourceRuntime
    let url: String?
    var maxPixel = 480

    @State private var image: UIImage?
    /// The address `image` belongs to, so a reused cell never shows the previous cover.
    @State private var imageURL: String?
    @State private var failed = false

    /// What to draw right now: the loaded image, or one still in the memory cache.
    private var current: UIImage? {
        guard let url = url, !url.isEmpty else { return nil }
        if imageURL == url, let image = image { return image }
        return ImagePipeline.shared.cached(url: url, maxPixel: maxPixel)
    }

    var body: some View {
        // The picture is an overlay on a plain colour, so it can never be
        // larger than this view. Without that, a "fill" image spills outside
        // its frame and, although it is clipped from view there, still
        // swallows taps meant for neighbouring buttons. (That is what made
        // the source switch button dead under the banner.)
        Theme.surface
            .overlay(picture.allowsHitTesting(false))
            .clipped()
            .contentShape(Rectangle())
            .task(id: url ?? "") { await load() }
    }

    @ViewBuilder
    private var picture: some View {
        if let shown = current {
            Image(uiImage: shown).resizable().scaledToFill()
        } else if failed {
            Image(systemName: "photo").foregroundColor(Theme.line)
        }
    }

    private func load() async {
        failed = false
        guard let url = url, !url.isEmpty else { failed = true; return }
        if imageURL == url, image != nil { return }
        do {
            let loaded = try await ImagePipeline.shared.image(runtime: runtime, url: url, maxPixel: maxPixel)
            image = loaded
            imageURL = url
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}

/// A readable error with a retry button. The text can be selected and copied.
struct ErrorBox: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(.orange)
            Text(message)
                .font(.callout)
                .foregroundColor(Theme.text)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let retry = retry {
                Button(action: retry) { PrimaryLabel(text: "Try again", symbol: "arrow.clockwise") }
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .background(Theme.card().fill(Theme.surface))
    }
}

/// Cover with title underneath, used in rows and grids.
struct MangaCell: View {
    let runtime: SourceRuntime
    let manga: PartialManga
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(runtime: runtime, url: manga.image)
                .frame(width: width, height: width * 1.5)
                .clipShape(Theme.card(Theme.coverRadius))
            Text(manga.title)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(Theme.text)
            if let subtitle = manga.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.caption2).lineLimit(1).foregroundColor(Theme.muted)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(manga.title)
    }
}
