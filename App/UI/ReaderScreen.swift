import SwiftUI
import UIKit

/// First, simple reader: paged, right-to-left (swipe right for the next page,
/// like a printed manga), pinch or double-tap to zoom.
struct ReaderScreen: View {
    let runtime: SourceRuntime
    let mangaId: String
    let chapter: Chapter

    @Environment(\.dismiss) private var dismiss
    @State private var pages: [String]?
    @State private var error: String?
    @State private var page = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let error = error {
                ErrorBox(message: error) { Task { await load() } }
            } else if let pages = pages {
                if pages.isEmpty {
                    Text("This chapter has no pages.").foregroundColor(.secondary)
                } else {
                    PagedReader(runtime: runtime, pages: pages, rightToLeft: true, page: $page)
                        .ignoresSafeArea()
                }
            } else {
                ProgressView("Loading pages…")
            }
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close reader")
                    Spacer()
                    if let pages = pages, !pages.isEmpty {
                        Text("\(page + 1) / \(pages.count)")
                            .font(.footnote.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            .accessibilityLabel("Page \(page + 1) of \(pages.count)")
                    }
                }
                .padding(12)
                Spacer()
            }
            .foregroundColor(.white)
        }
        .statusBar(hidden: true)
        .task { if pages == nil { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let details = try await runtime.call(ChapterDetails.self, "getChapterDetails", [mangaId, chapter.id])
            pages = details.pages ?? []
            Log.info("[\(runtime.sourceId)] chapter \(chapter.id): \(pages?.count ?? 0) pages")
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// UIKit page view controller wrapped for SwiftUI. UIKit is used here on
/// purpose: it only keeps the current page and its neighbours alive.
struct PagedReader: UIViewControllerRepresentable {
    let runtime: SourceRuntime
    let pages: [String]
    let rightToLeft: Bool
    @Binding var page: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                              options: [.interPageSpacing: 10])
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        if let first = context.coordinator.controller(at: 0) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {}

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private let parent: PagedReader

        init(_ parent: PagedReader) { self.parent = parent }

        func controller(at index: Int) -> PageViewController? {
            guard index >= 0, index < parent.pages.count else { return nil }
            let vc = PageViewController(runtime: parent.runtime, url: parent.pages[index], index: index)
            // Start loading right away: this is what preloads the next page.
            vc.loadViewIfNeeded()
            return vc
        }

        // "Before" is the page revealed by swiping right. In right-to-left
        // reading that is the NEXT page.
        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let current = vc as? PageViewController else { return nil }
            return controller(at: current.index + (parent.rightToLeft ? 1 : -1))
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let current = vc as? PageViewController else { return nil }
            return controller(at: current.index + (parent.rightToLeft ? -1 : 1))
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first as? PageViewController else { return }
            parent.page = current.index
        }
    }
}

/// One page: a zoomable image with loading and error states.
final class PageViewController: UIViewController, UIScrollViewDelegate {
    let index: Int
    private let runtime: SourceRuntime
    private let url: String
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retryButton = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?

    init(runtime: SourceRuntime, url: String, index: Int) {
        self.runtime = runtime
        self.url = url
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Page \(index + 1)"
        scrollView.addSubview(imageView)

        spinner.color = .white
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        view.addSubview(spinner)

        retryButton.titleLabel?.numberOfLines = 0
        retryButton.titleLabel?.textAlignment = .center
        retryButton.frame = view.bounds.insetBy(dx: 40, dy: 40)
        retryButton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(load), for: .touchUpInside)
        view.addSubview(retryButton)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        load()
    }

    @objc private func load() {
        retryButton.isHidden = true
        spinner.startAnimating()
        loadTask?.cancel()
        let runtime = self.runtime
        let url = self.url
        loadTask = Task { [weak self] in
            do {
                // 2048 px on the longest side matches the iPad's screen and
                // keeps one decoded page at 16 MB or less.
                let image = try await ImagePipeline.shared.image(runtime: runtime, url: url, maxPixel: 2048)
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.imageView.image = image
                }
            } catch is CancellationError {
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.retryButton.setTitle("Page \((self?.index ?? 0) + 1) failed to load.\n\(message)\n\nTap to try again.", for: .normal)
                    self?.retryButton.isHidden = false
                }
            }
        }
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // Rotation: go back to the fitted page so the layout stays correct.
        scrollView.setZoomScale(1, animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scrollView.setZoomScale(1, animated: false)
    }
}
