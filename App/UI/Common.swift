import SwiftUI

/// An image loaded through a source (covers). Shows a neutral box while
/// loading and a small icon if it fails.
struct RemoteImage: View {
    let runtime: SourceRuntime
    let url: String?
    var maxPixel = 400

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Theme.surface
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                Image(systemName: "photo").foregroundColor(Theme.line)
            }
        }
        .task(id: url ?? "") {
            guard let url = url, !url.isEmpty else { failed = true; return }
            do {
                image = try await ImagePipeline.shared.image(runtime: runtime, url: url, maxPixel: maxPixel)
            } catch is CancellationError {
            } catch {
                failed = true
            }
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
                Button("Try again", action: retry).buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
    }
}

/// Cover with title underneath, used in rows and grids.
struct MangaCell: View {
    let runtime: SourceRuntime
    let manga: PartialManga
    var width: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(runtime: runtime, url: manga.image)
                .frame(width: width, height: width * 1.5)
                .clipped()
            Text(manga.title)
                .font(.footnote)
                .lineLimit(2)
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
