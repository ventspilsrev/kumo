import SwiftUI
import UIKit

/// The reader. Right-to-left paging like a printed manga. In landscape it
/// shows two pages side by side (first page on the right); in portrait one.
struct ReaderScreen: View {
    let runtime: SourceRuntime
    let mangaId: String
    /// Chapters in reading order (oldest first).
    let chapters: [Chapter]

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.twoPages") private var twoPages = true

    @State private var index: Int
    @State private var page: Int
    @State private var lastShown: Int
    @State private var pages: [String]?
    @State private var error: String?
    @State private var showBar = true
    @State private var offset: Bool

    private var offsetKey: String { "reader.offset|\(runtime.sourceId)|\(mangaId)" }
    private var chapter: Chapter { chapters[index] }

    init(runtime: SourceRuntime, mangaId: String, chapters: [Chapter], index: Int, startPage: Int) {
        self.runtime = runtime
        self.mangaId = mangaId
        self.chapters = chapters
        _index = State(initialValue: min(max(index, 0), max(chapters.count - 1, 0)))
        _page = State(initialValue: max(startPage, 0))
        _lastShown = State(initialValue: max(startPage, 0))
        _offset = State(initialValue: UserDefaults.standard.bool(forKey: "reader.offset|\(runtime.sourceId)|\(mangaId)"))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            if showBar || pages == nil || error != nil { bar }
        }
        .statusBar(hidden: true)
        .task(id: index) { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }     // keep the screen on while reading
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private var content: some View {
        if let error = error {
            ErrorBox(message: error) { Task { await load() } }
        } else if let pages = pages {
            if pages.isEmpty {
                Text("This chapter has no pages.").foregroundColor(Theme.muted)
            } else {
                PagedReader(
                    runtime: runtime,
                    pages: pages,
                    startPage: min(page, pages.count - 1),
                    twoPages: twoPages,
                    offset: offset,
                    nextChapterTitle: index + 1 < chapters.count ? chapters[index + 1].displayTitle : nil,
                    onPage: { first, last in pageChanged(first: first, last: last, count: pages.count) },
                    onTapCenter: { withAnimation(.easeOut(duration: 0.15)) { showBar.toggle() } },
                    onNextChapter: { open(index + 1) })
                    // A new controller is built when the chapter or the layout options change.
                    .id("\(chapter.id)|\(twoPages)|\(offset)")
                    .ignoresSafeArea()
            }
        } else {
            ProgressView("Loading pages…").foregroundColor(Theme.muted)
        }
    }

    private var bar: some View {
        VStack {
            HStack(spacing: 12) {
                barButton("xmark", label: "Close reader") { dismiss() }
                Text(chapter.displayTitle)
                    .font(.footnote)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(Color.black.opacity(0.7))
                Spacer()
                if let pages = pages, !pages.isEmpty {
                    Text(lastShown > page ? "\(page + 1)–\(lastShown + 1) / \(pages.count)" : "\(page + 1) / \(pages.count)")
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(Color.black.opacity(0.7))
                        .accessibilityLabel("Page \(page + 1) of \(pages.count)")
                    if twoPages {
                        barButton("arrow.left.arrow.right", label: "Shift pages by one, if the two pages shown do not belong together") {
                            offset.toggle()
                            UserDefaults.standard.set(offset, forKey: offsetKey)
                        }
                    }
                    barButton(twoPages ? "book" : "doc", label: twoPages ? "Two pages in landscape: on" : "Two pages in landscape: off") {
                        twoPages.toggle()
                    }
                }
            }
            .padding(12)
            Spacer()
        }
        .foregroundColor(.white)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.7))
        }
        .accessibilityLabel(label)
    }

    private func pageChanged(first: Int, last: Int, count: Int) {
        page = first
        lastShown = last
        library.savePosition(sourceId: runtime.sourceId, mangaId: mangaId, chapterId: chapter.id,
                             page: first, pageCount: count, finished: last >= count - 1)
    }

    private func open(_ newIndex: Int) {
        guard newIndex >= 0, newIndex < chapters.count else { return }
        pages = nil
        page = 0
        lastShown = 0
        index = newIndex   // triggers load() through .task(id:)
    }

    private func load() async {
        error = nil
        pages = nil
        do {
            let details = try await runtime.call(ChapterDetails.self, "getChapterDetails", [mangaId, chapter.id])
            let list = details.pages ?? []
            Log.info("[\(runtime.sourceId)] chapter \(chapter.id): \(list.count) pages")
            pages = list
            if !list.isEmpty {
                let start = min(page, list.count - 1)
                pageChanged(first: start, last: start, count: list.count)
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Bridges the UIKit reader into SwiftUI.
struct PagedReader: UIViewControllerRepresentable {
    let runtime: SourceRuntime
    let pages: [String]
    let startPage: Int
    let twoPages: Bool
    let offset: Bool
    let nextChapterTitle: String?
    let onPage: (Int, Int) -> Void
    let onTapCenter: () -> Void
    let onNextChapter: () -> Void

    func makeUIViewController(context: Context) -> ReaderController {
        ReaderController(config: self)
    }

    func updateUIViewController(_ controller: ReaderController, context: Context) {
        controller.config = self   // keep callbacks current
    }
}

/// Owns the page view controller and decides which pages form a spread.
///
/// UIKit is used on purpose: UIPageViewController only keeps the visible
/// spread and its two neighbours alive, which bounds memory.
final class ReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var config: PagedReader

    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 12])
    private let rightToLeft = true
    /// Pages found to be wider than tall (already a double page). They are always shown alone.
    private var wide: [Int: Bool] = [:]
    private var currentFirst: Int
    private var laidOutDouble: Bool?
    private var turning = false

    init(config: PagedReader) {
        self.config = config
        self.currentFirst = config.startPage
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var count: Int { config.pages.count }
    private var isDouble: Bool { config.twoPages && view.bounds.width > view.bounds.height }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pager.view.backgroundColor = .black
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.dataSource = self
        pager.delegate = self

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        view.addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        single.require(toFail: double)
        view.addGestureRecognizer(single)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // First layout, and every rotation that switches between one and two pages.
        if laidOutDouble != isDouble {
            laidOutDouble = isDouble
            show(startingAt: currentFirst)
        }
    }

    // MARK: Spreads

    /// The pages shown together when a spread starts at `start`.
    private func spread(at start: Int) -> [Int] {
        guard isDouble else { return [start] }
        if config.offset && start == 0 { return [0] }          // cover alone
        if wide[start] == true { return [start] }
        let next = start + 1
        if next < count, wide[next] != true { return [start, next] }
        return [start]
    }

    /// The spread that ends just before page `start` (going backwards).
    private func spread(endingBefore start: Int) -> [Int]? {
        let last = start - 1
        guard last >= 0 else { return nil }
        guard isDouble else { return [last] }
        if wide[last] == true { return [last] }
        let first = last - 1
        let lowest = config.offset ? 1 : 0
        if first >= lowest, wide[first] != true { return [first, last] }
        return [last]
    }

    /// Moves a page index onto the start of its pair, so that pairs stay the
    /// same after rotating or reopening.
    private func aligned(_ start: Int) -> Int {
        guard isDouble else { return start }
        let base = config.offset ? 1 : 0
        if start > base, (start - base) % 2 == 1, wide[start] != true, wide[start - 1] != true { return start - 1 }
        return start
    }

    private func makeSpread(_ indices: [Int]) -> SpreadViewController {
        let vc = SpreadViewController(runtime: config.runtime, indices: indices, urls: indices.map { config.pages[$0] },
                                      rightToLeft: rightToLeft, maxPixel: indices.count == 2 ? 1600 : 2048)
        vc.onWide = { [weak self, weak vc] index in
            guard let self = self, let vc = vc else { return }
            self.wide[index] = true
            // The neighbours were planned before this was known. If this is
            // the visible spread, drop them so they are planned again.
            if self.pager.viewControllers?.first === vc, !self.turning {
                self.pager.setViewControllers([vc], direction: .forward, animated: false)
                self.report(vc)
            }
        }
        vc.loadViewIfNeeded()   // starts loading now: this is the preloading
        return vc
    }

    private func show(startingAt start: Int) {
        guard count > 0 else { return }
        let first = aligned(min(max(start, 0), count - 1))
        let vc = makeSpread(spread(at: first))
        pager.setViewControllers([vc], direction: .forward, animated: false)
        report(vc)
    }

    private func report(_ vc: UIViewController?) {
        if let spread = vc as? SpreadViewController, let first = spread.indices.first, let last = spread.indices.last {
            currentFirst = first
            config.onPage(first, last)
        } else if vc is EndViewController, count > 0 {
            config.onPage(count - 1, count - 1)
        }
    }

    /// The neighbour in reading direction (`forward`) or against it.
    private func neighbour(of vc: UIViewController, forward: Bool) -> UIViewController? {
        if let spread = vc as? SpreadViewController {
            if forward {
                let next = (spread.indices.last ?? 0) + 1
                if next < count { return makeSpread(self.spread(at: next)) }
                let end = EndViewController(nextTitle: config.nextChapterTitle)
                end.onNext = { [weak self] in self?.config.onNextChapter() }
                return end
            }
            return self.spread(endingBefore: spread.indices.first ?? 0).map(makeSpread)
        }
        if vc is EndViewController, !forward {
            return self.spread(endingBefore: count).map(makeSpread)
        }
        return nil
    }

    // "Before" is the page on the LEFT. Reading right-to-left, the next page is on the left.
    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        neighbour(of: vc, forward: rightToLeft)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        neighbour(of: vc, forward: !rightToLeft)
    }

    func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
        turning = true
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        turning = false
        if completed { report(pvc.viewControllers?.first) }
    }

    // MARK: Taps

    /// Left third and right third turn the page, the middle shows or hides the bar.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: view).x / max(view.bounds.width, 1)
        if x > 0.3 && x < 0.7 { config.onTapCenter(); return }
        guard !turning, let current = pager.viewControllers?.first else { return }
        if let spread = current as? SpreadViewController, spread.isZoomed { return }
        let leftSide = x <= 0.3
        let forward = leftSide == rightToLeft
        guard let target = neighbour(of: current, forward: forward) else { return }
        turning = true
        pager.setViewControllers([target], direction: leftSide ? .reverse : .forward, animated: true) { [weak self] _ in
            self?.turning = false
            self?.report(target)
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        (pager.viewControllers?.first as? SpreadViewController)?.toggleZoom(at: gesture)
    }
}

/// One or two pages shown together, zoomable as a unit.
final class SpreadViewController: UIViewController, UIScrollViewDelegate {
    private(set) var indices: [Int]
    var onWide: ((Int) -> Void)?

    private let rightToLeft: Bool
    private let scrollView = UIScrollView()
    private let container = UIView()
    private var slots: [PageSlot] = []

    init(runtime: SourceRuntime, indices: [Int], urls: [String], rightToLeft: Bool, maxPixel: Int) {
        self.indices = indices
        self.rightToLeft = rightToLeft
        super.init(nibName: nil, bundle: nil)
        for (i, url) in urls.enumerated() {
            let slot = PageSlot(runtime: runtime, url: url, index: indices[i], maxPixel: maxPixel)
            slot.onSize = { [weak self] size in self?.imageSized(index: indices[i], size: size) }
            slots.append(slot)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isZoomed: Bool { scrollView.zoomScale > 1.01 }

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
        scrollView.addSubview(container)
        slots.forEach { container.addSubview($0); $0.start() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isZoomed else { return }
        layoutSlots()
    }

    private func layoutSlots() {
        let bounds = scrollView.bounds
        container.frame = CGRect(origin: .zero, size: bounds.size)
        scrollView.contentSize = bounds.size
        if slots.count == 2 {
            let half = bounds.width / 2
            // Reading right-to-left: the first page sits on the right.
            let first = rightToLeft ? CGRect(x: half, y: 0, width: half, height: bounds.height)
                                    : CGRect(x: 0, y: 0, width: half, height: bounds.height)
            let second = rightToLeft ? CGRect(x: 0, y: 0, width: half, height: bounds.height)
                                     : CGRect(x: half, y: 0, width: half, height: bounds.height)
            // Each page hugs the middle so the two meet like an open book.
            slots[0].alignment = rightToLeft ? .left : .right
            slots[1].alignment = rightToLeft ? .right : .left
            slots[0].frame = first
            slots[1].frame = second
        } else if let only = slots.first {
            only.alignment = .center
            only.frame = container.bounds
        }
        slots.forEach { $0.setNeedsLayout() }
    }

    /// A page that is wider than tall is already a double page: show it alone.
    private func imageSized(index: Int, size: CGSize) {
        guard size.width > size.height * 1.05 else { return }
        if slots.count == 2 {
            // Keep only the first page of the pair; the other one moves to the next spread.
            let removed = slots.removeLast()
            removed.cancel()
            removed.removeFromSuperview()
            indices = [indices[0]]
            scrollView.setZoomScale(1, animated: false)
            layoutSlots()
        }
        onWide?(index)
    }

    func toggleZoom(at gesture: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: container)
            let size = CGSize(width: scrollView.bounds.width / 2.2, height: scrollView.bounds.height / 2.2)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        scrollView.setZoomScale(1, animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scrollView.setZoomScale(1, animated: false)
    }
}

/// One page image with its own loading and error state.
final class PageSlot: UIView {
    enum Alignment { case left, center, right }

    var alignment: Alignment = .center
    var onSize: ((CGSize) -> Void)?

    private let runtime: SourceRuntime
    private let url: String
    private let index: Int
    private let maxPixel: Int
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retryButton = UIButton(type: .system)
    private var task: Task<Void, Never>?

    init(runtime: SourceRuntime, url: String, index: Int, maxPixel: Int) {
        self.runtime = runtime
        self.url = url
        self.index = index
        self.maxPixel = maxPixel
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Page \(index + 1)"
        addSubview(imageView)
        spinner.color = .white
        addSubview(spinner)
        retryButton.titleLabel?.numberOfLines = 0
        retryButton.titleLabel?.textAlignment = .center
        retryButton.tintColor = Theme.uiText
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(start), for: .touchUpInside)
        addSubview(retryButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { task?.cancel() }

    func cancel() { task?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        retryButton.frame = bounds.insetBy(dx: 24, dy: 24)
        guard let size = imageView.image?.size, size.width > 0, size.height > 0, bounds.width > 0 else {
            imageView.frame = bounds
            return
        }
        // Fit inside the slot, then push towards the chosen side.
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        let x: CGFloat
        switch alignment {
        case .left: x = 0
        case .right: x = bounds.width - fitted.width
        case .center: x = (bounds.width - fitted.width) / 2
        }
        imageView.frame = CGRect(x: x, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    @objc func start() {
        retryButton.isHidden = true
        spinner.startAnimating()
        task?.cancel()
        let runtime = self.runtime, url = self.url, maxPixel = self.maxPixel, number = index + 1
        task = Task { [weak self] in
            do {
                let image = try await ImagePipeline.shared.image(runtime: runtime, url: url, maxPixel: maxPixel)
                await MainActor.run {
                    guard let self = self else { return }
                    self.spinner.stopAnimating()
                    self.imageView.image = image
                    self.setNeedsLayout()
                    self.onSize?(image.size)
                }
            } catch is CancellationError {
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard let self = self else { return }
                    self.spinner.stopAnimating()
                    self.retryButton.setTitle("Page \(number) failed to load.\n\(message)\n\nTap to try again.", for: .normal)
                    self.retryButton.isHidden = false
                }
            }
        }
    }
}

/// Shown after the last page of a chapter.
final class EndViewController: UIViewController {
    var onNext: (() -> Void)?
    private let nextTitle: String?

    init(nextTitle: String?) {
        self.nextTitle = nextTitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.uiBackground

        let title = UILabel()
        title.text = "End of chapter"
        title.textColor = Theme.uiText
        title.font = UIFont.preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [title])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20

        if let nextTitle = nextTitle {
            var configuration = UIButton.Configuration.filled()
            configuration.title = "Next: \(nextTitle)"
            configuration.baseBackgroundColor = Theme.uiAccent
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .small
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onNext?() })
            stack.addArrangedSubview(button)
        } else {
            let note = UILabel()
            note.text = "You have reached the newest chapter."
            note.textColor = Theme.uiMuted
            note.font = UIFont.preferredFont(forTextStyle: .body)
            note.adjustsFontForContentSizeCategory = true
            stack.addArrangedSubview(note)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }
}
