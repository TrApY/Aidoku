//
//  ReaderWebtoonViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 9/27/22.
//

import AidokuRunner
import AsyncDisplayKit
import Nuke
import UIKit

class ReaderWebtoonViewController: ZoomableCollectionViewController {
    let viewModel: ReaderWebtoonViewModel
    weak var delegate: ReaderHoldingDelegate?

    var chapter: AidokuRunner.Chapter?
    var readingMode: ReadingMode = .webtoon {
        didSet {
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
            layout?.spacing = readingMode == .webtoon ? 0 : 15
            collectionNode.invalidateCalculatedLayout()
        }
    }

    private let pillarboxLayoutState = ReaderPillarboxLayoutState()

    // Indicates if infinite scroll is enabled
    private lazy var infinite = UserDefaults.standard.bool(forKey: "Reader.verticalInfiniteScroll")
    // How many pages before the end of the last chapter the next one starts loading, and how many pages after the
    // screen are loaded and measured before they show (SUWA-17 C)
    private lazy var pagesToPreload = UserDefaults.standard.integer(forKey: "Reader.pagesToPreload")
    // How many chapters we allow to be held in memory
    private let maxRetainedChapters = 3
    private var loadingPrevious = false
    /// The last page on screen when the pages around it were last asked to be measured.
    private var measuredAheadFrom: IndexPath?
    /// After a memory warning nothing is measured ahead for a while.
    /// Until when nothing is measured ahead, after a memory warning (internal for the tests).
    var measureAheadPausedUntil: Date?
    /// The pages that may hold a decoded image (SUWA-29 B): the one right above the screen, the ones on screen and the
    /// ones that start within the 4 screens below it (Texture's preload range), at least «pages to preload» + 2
    /// from the first one on screen and at most `decodeMaxPages` from it. After a memory warning, for as long as
    /// nothing is measured ahead, only «pages to preload» + 2 from the first one on screen, as before (SUWA-17 E1).
    private let decodeWindow = NSHashTable<ReaderWebtoonPageNode>.weakObjects()
    /// How many screens below the screen the pages may hold a decoded image.
    static let decodeScreensBelow: CGFloat = 4
    /// At most this many pages from the first one on screen (pages much shorter than the screen).
    static let decodeMaxPages = 24
    /// The pages out of it that could not let go of their image yet (on screen for Texture a moment longer).
    private let decodeLeaving = NSHashTable<ReaderWebtoonPageNode>.weakObjects()
    private var loadingNext = false
    /// The data of the pages coming from the network, to the disk cache without decoding them (SUWA-29 C): when they get
    /// into the preload range their image comes from the disk. Leaving the reader stops it, and the pages that are no
    /// longer among the next ones stop.
    private lazy var pagePrefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher(pipeline: .shared, destination: .diskCache, maxConcurrentRequestCount: 2)
        // after the pages loading to show and the measuring ahead
        prefetcher.priority = .veryLow
        return prefetcher
    }()
    /// What it is downloading now, by address.
    private var prefetching: [URL: ImageRequest] = [:]
    /// How many pages after the last one on screen have their data downloaded ahead.
    static let pagesToDownloadAhead = 10
    /// The reader is shown (between viewWillAppear and viewWillDisappear): only then is anything downloaded ahead.
    private var isInFront = true

    // The chapters currently shown in the reader view
    private var chapters: [AidokuRunner.Chapter] = []
    // The pages corresponding to the `chapters` variable
    private var pages: [[Page]] = []
    private var dictionaryOverlayTapHandler: ((String, String, CGRect, [CGRect]) -> Void)?
    private var dictionaryOverlayInteractionMode: DictionaryOverlayInteractionMode = .none

    // Indicates if the page slider is currently in use
    private var isSliding = false
    // Indicates if a zoom gesture is in progress
    var isZooming = false
    // Indicates if a scroll is in progress
    private var isScrolling = false
    // Indicates if an info refresh should be done if info pages are off screen
    private var needsInfoRefresh = false
    /// The screen is being put on the anchor (its own scrolls are not the user's nor to be put back).
    private var applyingAnchor = false
    private(set) var isContentScrolling = false {
        didSet {
            guard isContentScrolling != oldValue else { return }
            onContentScrollingChange?(isContentScrolling)
        }
    }

    // Stores the last calculated page number
    /// Reports only real page changes, and the first page of each chapter.
    private var pageReports = PageReportFilter()
    /// Where the user is reading (SUWA-19): this point of this item at this height of the screen. Only the user
    /// moves it (dragging and its deceleration, the auto scroll, turning a page, the slider, a zoom that ends) and
    /// opening a chapter, which puts the top of its page at the top of the screen; the page reported is the
    /// anchor's. Before, the page was the one in the middle of the screen, and the pages above growing as their
    /// images loaded made it the one before (SUWA-16: openingPageHold held the opening page until the user moved).
    private(set) var anchor: ReadingAnchor?
    /// The anchor was written by the user (not the opening one): only then is its fraction reported (SUWA-19 D12).
    private var anchorIsTheUsers = false
    /// The position last reported with a page (page + fraction), to report a new fraction of the same page.
    private var reportedPosition: Double?
    /// Where in its start page the next chapter opened with setChapter goes (0 its top, 1 its bottom), in the
    /// middle of the screen; nil: the top of the page at the top of the screen (SUWA-19 D12, D14).
    var openingFraction: Double?
    /// Entering the previous chapter from below by scrolling: how far into its section the screen was. Once the
    /// user goes half a screen further up inside it, they are reading it (SUWA-17 F3: a chapter of one page, or a
    /// last page taller than the screen, has no page before the last to report).
    private var enteredFromBelowAt: CGFloat?
    /// After going up inside it: where the user entered and the highest point they went up to. Going down after
    /// going a whole screen above where they entered is reading it: its page is told again (SUWA-17 G1).
    private var wentUpInside: (entry: CGFloat, highest: CGFloat)?
    /// The user is dragging the content, or it decelerates after their drag: not the layout moving it (SUWA-17 G2).
    private var userIsScrolling = false
    /// Turning a page (tap, key): its scroll may take the reader into another chapter (SUWA-17 H).
    private var turningPage = false
    /// Chapters whose end this reader already wrote to the completion journal (once each).
    private var journaledEnds = Set<String>()

    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollLastTimestamp: CFTimeInterval?
    private var autoScrollPausedForUserInteraction = false

    private(set) var isAutoScrolling = false {
        didSet {
            guard isAutoScrolling != oldValue else { return }
            onAutoScrollStateChange?(isAutoScrolling)
        }
    }
    var onAutoScrollStateChange: ((Bool) -> Void)?
    var onContentScrollingChange: ((Bool) -> Void)?

    init(
        source: AidokuRunner.Source?,
        manga: AidokuRunner.Manga,
        temporaryPageStore: ReaderTemporaryPageStore
    ) {
        self.viewModel = ReaderWebtoonViewModel(
            source: source,
            manga: manga,
            temporaryPageStore: temporaryPageStore
        )
        super.init(layout: VerticalContentOffsetPreservingLayout())
    }

    deinit {
        autoScrollDisplayLink?.invalidate()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isInFront = true
        // back in front: the next scroll asks again for the pages after the screen
        measuredAheadFrom = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // leaving the reader (or another reader taking its place): the data of the pages coming stops, and nothing
        // more is asked for while it is away (its layout still moves as it goes) (SUWA-29 C)
        isInFront = false
        stopDownloadingAhead()
    }

    override func configure() {
        super.configure()

        collectionNode.delegate = self
        collectionNode.dataSource = self
//        collectionNode.view.prefetchDataSource = self
//        collectionNode.isPrefetchingEnabled = true

        // More ahead than Texture's own ranges, in screens (SUWA-29 B): the pages are put in their cells (display) from 2
        // screens below the screen (before, 1) and load from 4 screens below (preload; before, 2.5), so a quick scroll
        // does not get to a page that is still black. Texture's own ranges with little memory, as before. «Leading» is
        // below the screen: the collection inside never scrolls itself (the zoom view's scroll view does), so Texture
        // keeps the direction it starts with, down.
        let textureDisplay = collectionNode.tuningParameters(for: .display)
        let texturePreload = collectionNode.tuningParameters(for: .preload)
        let display = ASRangeTuningParameters(leadingBufferScreenfuls: 2, trailingBufferScreenfuls: 0.75)
        let preload = ASRangeTuningParameters(leadingBufferScreenfuls: 4, trailingBufferScreenfuls: 1.5)
        collectionNode.setTuningParameters(display, for: .display)
        collectionNode.setTuningParameters(preload, for: .preload)
        // override texture's automatic decreased preloading range
        collectionNode.setTuningParameters(display, for: .minimum, rangeType: .display)
        collectionNode.setTuningParameters(preload, for: .minimum, rangeType: .preload)
        collectionNode.setTuningParameters(textureDisplay, for: .lowMemory, rangeType: .display)
        collectionNode.setTuningParameters(texturePreload, for: .lowMemory, rangeType: .preload)

        scrollView.contentInset = .zero
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false // bouncing can cause issues with page appending
        scrollView.scrollsToTop = false // dont want status bar tap to work
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handleAutoScrollPan(_:)))
        scrollNode.insetsLayoutMarginsFromSafeArea = false

        scrollView.topEdgeEffect.style = .soft
        scrollView.bottomEdgeEffect.style = .soft
        collectionNode.view.topEdgeEffect.isHidden = true
        collectionNode.view.bottomEdgeEffect.isHidden = true

        collectionNode.contentInset = .zero
        collectionNode.showsVerticalScrollIndicator = false
        collectionNode.showsHorizontalScrollIndicator = false
        collectionNode.view.contentInsetAdjustmentBehavior = .never
        collectionNode.view.bounces = false
        collectionNode.view.scrollsToTop = false

        collectionNode.automaticallyManagesSubnodes = true
        collectionNode.shouldAnimateSizeChanges = false
        collectionNode.insetsLayoutMarginsFromSafeArea = false

        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        updateDoubleTapZoomSetting()

        zoomView.onZoomScaleChanged = { [weak self] scale in
            self?.setLiveTextButtonHidden(scale != 1)
        }
        // a double tap's zoom is the user moving; the layout puts the screen on the anchor (SUWA-19)
        zoomView.onZoomAnimationEnded = { [weak self] in
            guard let self else { return }
            self.writeAnchorFromScreen()
            // the chapter follows the anchor now, not at the next scroll event (hallazgo 5)
            self.scrollViewDidScroll(self.collectionNode.view)
        }
        (collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout)?.anchorTarget = { [weak self] in
            self?.anchorTarget()
        }
        // pages that grow or shrink with the screen still move the ones below in or out of the pages to decode
        // (SUWA-29 B): those follow at the next turn, not only when the screen moves
        zoomView.onContentSizeChanged = { [weak self] in
            self?.scheduleDecodeWindowUpdate()
        }

        // set initial portrait state before view presentation
        let isPortrait = view.bounds.size.height >= view.bounds.size.width
        pillarboxLayoutState.setIsPortrait(isPortrait)
    }

    override func observe() {
        addObserver(forName: "Reader.verticalInfiniteScroll") { [weak self] notification in
            self?.infinite = notification.object as? Bool ?? UserDefaults.standard.bool(forKey: "Reader.verticalInfiniteScroll")
        }
        for key in [
            "Reader.disableDoubleTap",
            AppSettings.dictionary.enable.key,
            AppSettings.dictionary.lookupGesture.key,
            AppSettings.dictionary.restrictOCRLanguages.key,
            AppSettings.dictionary.restrictedOCRLanguages.key
        ] {
            addObserver(forName: key) { [weak self] _ in
                self?.updateDoubleTapZoomSetting()
            }
        }
        addObserver(forName: "Reader.pagesToPreload") { [weak self] notification in
            self?.pagesToPreload = notification.object as? Int
                ?? UserDefaults.standard.integer(forKey: "Reader.pagesToPreload")
        }
        addObserver(forName: .readerShowingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(false)
        }
        addObserver(forName: .readerHidingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(true)
        }

        addObserver(forName: UIApplication.didReceiveMemoryWarningNotification.rawValue) { [weak self] _ in
            LogManager.logger.warn("Received memory warning in webtoon reader")
            // the pages stop being measured ahead for half a minute (each one cancels its own)
            self?.measureAheadPausedUntil = Date().addingTimeInterval(30)
            self?.measuredAheadFrom = nil

            // clear image memory cache
            ImagePipeline.shared.configuration.imageCache?.removeAll()
        }
    }

    enum ScreenPosition {
        case top
        case middle
        case bottom
    }

    /// Get the current row of the page view at `pos`
    func getCurrentPagePath(pos: ScreenPosition = .middle) -> IndexPath? {
        let additional: CGFloat
        switch pos {
            case .top: additional = 0
            case .middle: additional = collectionNode.bounds.height / 2
            case .bottom: additional = collectionNode.bounds.height
        }
        let currentPoint = CGPoint(x: collectionNode.contentOffset.x, y: collectionNode.contentOffset.y + additional)
        return collectionNode.indexPathForItem(at: currentPoint)
    }

    func getCurrentPage() -> Int {
        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let currentPages = pages[safe: chapterIndex]
        else { return 0 }
        let pageRow = getCurrentPagePath()?.row ?? 0
        let hasStartInfo = currentPages.first?.type != .imagePage
        return min(
            max(pageRow + (hasStartInfo ? 0 : 1), 0),
            currentPages.count - (hasStartInfo ? 1 : 0)
        )
    }

    /// The anchor at the middle of the screen now: the item there and where in it (SUWA-19).
    func anchorAtScreen() -> ReadingAnchor? {
        guard
            let path = getCurrentPagePath(),
            let chapter = chapters[safe: path.section],
            let frame = collectionNode.collectionViewLayout.layoutAttributesForItem(at: path)?.frame,
            let found = ReadingAnchorGeometry.locate(
                lineY: collectionNode.contentOffset.y + collectionNode.bounds.height / 2,
                frames: [(item: path.item, frame: frame)]
            )
        else { return nil }
        // measured: the cell has another height than the provisional one (what the layout sees, not the node:
        // the node may know its ratio a pass before its cell has it)
        let node = collectionNode.nodeForItem(at: path) as? ReaderWebtoonPageNode
        return ReadingAnchor(
            chapterKey: chapter.key,
            item: found.item,
            fraction: found.fraction,
            screenFraction: 0.5,
            measured: node.map { abs(frame.height - $0.provisionalHeight(forWidth: frame.width)) > 0.5 } ?? true
        )
    }

    /// The user moved: the anchor is where the middle of the screen is now (nothing there: it stays). Not with the
    /// app out of front (SUWA-19 I7).
    private func writeAnchorFromScreen() {
        guard delegate?.appActivity.isActive ?? true, let new = anchorAtScreen() else { return }
        anchor = new
        anchorIsTheUsers = true
    }

    /// The position saved with `page` (D12): the page plus the anchor's fraction rounded down to a tenth, when the
    /// user put the anchor on that page (an image page); nil otherwise (the history keeps what it had). The anchor's
    /// page, as anchorPage() counts it: a chapter put in below starts with its first page, not with a transition
    /// (SUWA-19 revisión, hallazgo 1).
    private func positionToReport(page: Int) -> Double? {
        guard
            anchorIsTheUsers,
            let anchor,
            let chapter,
            anchor.chapterKey == chapter.key,
            anchorPage() == page,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let shown = pages[safe: chapterIndex]?[safe: anchor.item],
            shown.type == .imagePage,
            // not a text page: a text reader reads scrollPosition as its 0...1 progress (hallazgo 3)
            !shown.isTextPage
        else { return nil }
        return Double(page) + min(floor(Double(anchor.fraction) * 10) / 10, 0.9)
    }

    /// Where the layout puts the screen: the anchor's item and point (SUWA-19). Nothing while a zoom goes on (the
    /// gesture moves the content), nor while the collection does not have the reader's chapters yet (a batch not
    /// applied: the section would be another chapter's). An anchor taken on a page with its provisional height
    /// keeps its distance to the top of the page once the page has its real one (D6).
    private func anchorTarget() -> (indexPath: IndexPath, fraction: CGFloat, screenFraction: CGFloat)? {
        guard
            !isZooming,
            !zoomView.isAnimatingZoom,
            var anchor,
            let section = chapters.firstIndex(where: { $0.key == anchor.chapterKey }),
            collectionNode.view.numberOfSections == pages.count,
            let sectionPages = pages[safe: section],
            collectionNode.view.numberOfItems(inSection: section) == sectionPages.count,
            anchor.item < sectionPages.count
        else { return nil }
        let path = IndexPath(item: anchor.item, section: section)
        if
            !anchor.measured,
            let node = collectionNode.nodeForItem(at: path) as? ReaderWebtoonPageNode,
            let frame = collectionNode.collectionViewLayout.layoutAttributesForItem(at: path)?.frame,
            frame.height > 0
        {
            let provisional = node.provisionalHeight(forWidth: frame.width)
            if abs(frame.height - provisional) > 0.5 {
                anchor = ReadingAnchorGeometry.measured(anchor, provisionalHeight: provisional, realHeight: frame.height)
                self.anchor = anchor
            }
        }
        return (path, anchor.fraction, anchor.screenFraction)
    }

    /// The page of the anchor, counted as getCurrentPage() counts them, when it is in the current chapter.
    private func anchorPage() -> Int? {
        guard
            let anchor,
            let chapter,
            anchor.chapterKey == chapter.key,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let currentPages = pages[safe: chapterIndex]
        else { return nil }
        let hasStartInfo = currentPages.first?.type != .imagePage
        return min(
            max(anchor.item + (hasStartInfo ? 0 : 1), 0),
            currentPages.count - (hasStartInfo ? 1 : 0)
        )
    }

    /// The pages the reader asked to measure themselves ahead and still wants measured: the ones that leave it
    /// (left behind) stop (SUWA-17 E2).
    private let measureWanted = NSHashTable<ReaderWebtoonPageNode>.weakObjects()
    nonisolated let measureWantedIDs = ReaderDecodeWindow()

    nonisolated func wantsMeasure(_ node: ReaderWebtoonPageNode) -> Bool {
        measureWantedIDs.contains(node)
    }

    /// The same pages, to be asked from the pages' own callbacks.
    nonisolated let decodeWindowIDs = ReaderDecodeWindow()

    /// Whether the page may load and decode its image now (the ones on screen always may).
    nonisolated func mayDecode(_ node: ReaderWebtoonPageNode) -> Bool {
        decodeWindowIDs.contains(node)
    }

    /// Moves the pages that may hold a decoded image with the screen (not while zooming: the pages keep theirs): the ones that come in load, the ones that
    /// leave let go of their image (SUWA-17 E1).
    private func updateDecodeWindow() {
        guard
            !isZooming,
            let first = getCurrentPagePath(pos: .top) ?? getCurrentPagePath(),
            let last = getCurrentPagePath(pos: .bottom) ?? getCurrentPagePath()
        else { return }
        // after a memory warning, as few as before (the pause of the measuring ahead)
        let reduced = measureAheadPausedUntil.map { $0 > Date() } ?? false
        let layout = collectionNode.collectionViewLayout
        let limitY = collectionNode.contentOffset.y + collectionNode.bounds.height * (1 + Self.decodeScreensBelow)
        var window: [ReaderWebtoonPageNode] = []
        // only pages of the chapters shown: after another chapter is opened, the old ones are there until its pages come
        let shown = Set(chapters.map(\.key))
        func pageNode(at path: IndexPath) -> ReaderWebtoonPageNode? {
            (collectionNode.nodeForItem(at: path) as? ReaderWebtoonPageNode).flatMap { shown.contains($0.page.chapterId) ? $0 : nil }
        }
        // the page right above the screen keeps its image: going back up a little shows it at once
        if !reduced, let above = indexPath(before: first), let node = pageNode(at: above) {
            window.append(node)
        }
        var count = 0
        var path: IndexPath? = first
        while let current = path {
            let startsWithin = !reduced && (layout.layoutAttributesForItem(at: current)?.frame.minY ?? .infinity) < limitY
            guard
                current <= last
                    || (count < Self.decodeMaxPages && (count < max(0, pagesToPreload) + 2 || startsWithin))
            else { break }
            if let node = pageNode(at: current) {
                window.append(node)
            }
            count += 1
            path = indexPath(after: current)
        }
        // the ones that left (and the ones that could not let go before: still on screen for Texture)
        let leaving = decodeWindow.allObjects + decodeLeaving.allObjects
        decodeWindow.removeAllObjects()
        decodeLeaving.removeAllObjects()
        for node in window {
            decodeWindow.add(node)
        }
        decodeWindowIDs.set(window)
        for node in leaving where !decodeWindow.contains(node) && !node.decodeDisallowed() {
            decodeLeaving.add(node)
        }
        for node in window {
            node.decodeAllowed()
        }
    }

    private var decodeWindowUpdateScheduled = false

    /// The pages to decode follow the layout at the next turn of the main queue (once, however many passes).
    private func scheduleDecodeWindowUpdate() {
        guard !decodeWindowUpdateScheduled else { return }
        decodeWindowUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.decodeWindowUpdateScheduled = false
            self.updateDecodeWindow()
        }
    }

    /// Asks the «pages to preload» pages after the last one on screen, and two before the first one, to measure
    /// themselves before they show (SUWA-17 C). Once per change of the last page on screen.
    func measureAhead() {
        updateDecodeWindow()
        if let until = measureAheadPausedUntil {
            guard until <= Date() else { return }
            measureAheadPausedUntil = nil
        }
        guard
            let last = getCurrentPagePath(pos: .bottom) ?? getCurrentPagePath(),
            last != measuredAheadFrom
        else { return }
        measuredAheadFrom = last
        downloadAhead(from: last)
        let first = getCurrentPagePath(pos: .top) ?? last
        var paths: [IndexPath] = []
        var path = last
        for _ in 0..<max(1, pagesToPreload) {
            guard let next = indexPath(after: path) else { break }
            paths.append(next)
            path = next
        }
        path = first
        for _ in 0..<2 {
            guard let previous = indexPath(before: path) else { break }
            paths.append(previous)
            path = previous
        }
        let nodes = paths.compactMap { collectionNode.nodeForItem(at: $0) as? ReaderWebtoonPageNode }
        // the ones no longer wanted (left behind) stop measuring
        for node in measureWanted.allObjects where !nodes.contains(where: { $0 === node }) {
            node.cancelMeasureAhead()
        }
        measureWanted.removeAllObjects()
        for node in nodes {
            measureWanted.add(node)
        }
        measureWantedIDs.set(nodes)
        for node in nodes {
            node.measureAhead()
        }
    }

    /// The data of the `pagesToDownloadAhead` pages after `last` that come from the network (not downloaded, not from
    /// a source that processes its pages), to the disk cache; the ones that are no longer among them stop.
    private func downloadAhead(from last: IndexPath) {
        var wanted: [(url: URL, context: PageContext?)] = []
        if isInFront, viewModel.source?.features.processesPages != true {
            var path = last
            for _ in 0..<Self.pagesToDownloadAhead {
                guard let next = indexPath(after: path) else { break }
                path = next
                guard
                    let page = pages[safe: next.section]?[safe: next.item],
                    // a chapter shown (after another one is opened, the old pages are there until its pages come)
                    chapters.contains(where: { $0.key == page.chapterId }),
                    page.type == .imagePage,
                    page.zipURL == nil,
                    let string = page.imageURL,
                    let url = URL(string: string),
                    !url.isFileURL
                else { continue }
                wanted.append((url, page.context))
            }
        }
        let wantedURLs = Set(wanted.map(\.url))
        let leftBehind = prefetching.filter { !wantedURLs.contains($0.key) }
        if !leftBehind.isEmpty {
            pagePrefetcher.stopPrefetching(with: Array(leftBehind.values))
            for url in leftBehind.keys {
                prefetching[url] = nil
            }
        }
        let new = wanted.filter { prefetching[$0.url] == nil }
        guard !new.isEmpty else { return }
        let source = viewModel.source
        Task { @MainActor [weak self] in
            var requests: [URL: ImageRequest] = [:]
            for (url, context) in new {
                // the same request the page sends (the source's headers): its data is what the page finds on disk
                let urlRequest = if let source {
                    await source.getModifiedImageRequest(url: url, context: context)
                } else {
                    URLRequest(url: url)
                }
                requests[url] = ImageRequest(urlRequest: urlRequest)
            }
            guard let self else { return }
            for (url, request) in requests {
                self.prefetching[url] = request
            }
            self.pagePrefetcher.startPrefetching(with: Array(requests.values))
        }
    }

    /// Nothing more is downloaded ahead and what was going stops (another chapter, leaving the reader).
    private func stopDownloadingAhead() {
        pagePrefetcher.stopPrefetching()
        prefetching = [:]
        // when the reader comes back, the next scroll asks again
        measuredAheadFrom = nil
    }

    private func indexPath(after path: IndexPath) -> IndexPath? {
        if path.item + 1 < (pages[safe: path.section]?.count ?? 0) {
            return IndexPath(item: path.item + 1, section: path.section)
        }
        var section = path.section + 1
        while section < pages.count {
            if !pages[section].isEmpty { return IndexPath(item: 0, section: section) }
            section += 1
        }
        return nil
    }

    private func indexPath(before path: IndexPath) -> IndexPath? {
        if path.item > 0 {
            return IndexPath(item: path.item - 1, section: path.section)
        }
        var section = path.section - 1
        while section >= 0 {
            if !pages[section].isEmpty { return IndexPath(item: pages[section].count - 1, section: section) }
            section -= 1
        }
        return nil
    }

    /// Put the collection node back into the full preload range.
    private func restorePreloadRange() {
        (collectionNode as ASRangeControllerUpdateRangeProtocol).updateCurrentRange(with: .full)
    }

    private func canTrimSection(at index: Int) -> Bool {
        guard
            chapters.count > maxRetainedChapters,
            pages.indices.contains(index),
            chapters.indices.contains(index),
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
        else { return false }
        if let chapter, chapters.firstIndex(of: chapter) == index { return false }

        // test the section's frame against the viewport rather than sampling index paths
        guard
            !pages[index].isEmpty,
            let firstFrame = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: index))?.frame,
            let lastFrame = layout.layoutAttributesForItem(at: IndexPath(item: pages[index].count - 1, section: index))?.frame,
            firstFrame.height > 0,
            lastFrame.height > 0
        else { return false }
        let visible = CGRect(origin: collectionNode.contentOffset, size: collectionNode.bounds.size)
        return lastFrame.maxY <= visible.minY || firstFrame.minY >= visible.maxY
    }

    private func setLiveTextButtonHidden(_ hidden: Bool) {
        collectionNode.visibleNodes.forEach {
            guard let pageNode = $0 as? ReaderWebtoonPageNode else { return }
            if hidden || delegate?.barsHidden == true {
                pageNode.setLiveTextHidden(true)
            } else {
                let scale = zoomView.scrollNode.view.zoomScale
                pageNode.setLiveTextHidden(scale != 1)
            }
        }
    }

    private func updateDoubleTapZoomSetting() {
        let language = chapter?.language ?? viewModel.source?.languages.first
        zoomView.doubleTapEnabled = !AppSettings.dictionary.isReaderDoubleTapDisabled(language: language)
    }
}

// MARK: - Auto Scroll
extension ReaderWebtoonViewController {
    func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    func stopAutoScroll() {
        isAutoScrolling = false
        autoScrollPausedForUserInteraction = false
        autoScrollLastTimestamp = nil
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil

        updateContentScrollingState()
    }

    private func startAutoScroll() {
        guard !isAutoScrolling else { return }

        isAutoScrolling = true
        resumeAutoScroll()

        let displayLink = CADisplayLink(target: self, selector: #selector(handleAutoScrollFrame(_:)))
        displayLink.add(to: .main, forMode: .common)
        autoScrollDisplayLink = displayLink

        updateContentScrollingState()
    }

    func pauseAutoScroll() {
        guard isAutoScrolling else { return }
        autoScrollPausedForUserInteraction = true
        autoScrollLastTimestamp = nil
        updateContentScrollingState()
    }

    func resumeAutoScroll() {
        guard isAutoScrolling else { return }
        autoScrollPausedForUserInteraction = false
        autoScrollLastTimestamp = nil
        updateContentScrollingState()
    }

    @objc private func handleAutoScrollPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began else { return }
        pauseAutoScroll()
    }

    @objc private func handleAutoScrollFrame(_ displayLink: CADisplayLink) {
        defer { autoScrollLastTimestamp = displayLink.timestamp }

        guard
            isAutoScrolling,
            !autoScrollPausedForUserInteraction,
            !isZooming,
            !isSliding,
            let previousTimestamp = autoScrollLastTimestamp
        else {
            return
        }

        restorePreloadRange()

        let speed = max(UserDefaults.standard.integer(forKey: "Reader.autoScrollSpeed"), 1)
        let distance = CGFloat(speed * 100) * CGFloat(displayLink.timestamp - previousTimestamp)
        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let nextY = min(max(scrollView.contentOffset.y + distance, minimumY), maximumY)

        scrollView.setContentOffset(.init(x: scrollView.contentOffset.x, y: nextY), animated: false)

        if nextY >= maximumY {
            stopAutoScroll()

            if infinite {
                isScrolling = false
                checkInfiniteLoad()
            }
        }
    }

    private func updateContentScrollingState() {
        isContentScrolling =
            scrollView.isDragging
            || scrollView.isDecelerating
            || (isAutoScrolling && !autoScrollPausedForUserInteraction)
    }
}

// MARK: - Scroll View Delegate
extension ReaderWebtoonViewController {
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userIsScrolling = true
        turningPage = false
        super.scrollViewWillBeginDragging(scrollView)
        restorePreloadRange()
        pauseAutoScroll()
        setLiveTextButtonHidden(true)
        updateContentScrollingState()
    }

    // Update current page when scrolling
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)

        isScrolling = true

        // ignore if page slider is being used
        guard !isSliding && !isZooming else { return }

        // The layout or the reader putting the screen on the anchor: in between, one scroll view has the new offset
        // and the other the old one, which, with the content above changed, is another place (another chapter). That is
        // not the user moving, also during a drag or a deceleration (SUWA-19 revisión, hallazgo 4: pages shrinking
        // above during a deceleration took the reader into the next chapter). The anchor's page is still told
        let placing = applyingAnchor
            || (collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout)?.isPlacingTheScreen == true

        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter)
        else { return }

        // The user moving the content (dragging and its deceleration, the auto scroll, turning a page) moves the
        // anchor, with the app in front and a page in the middle of the screen (SUWA-17 H, SUWA-19); the content
        // moved by anything else (a layout pass, UIKit scaling the offset after a width change, the zoom's scroll
        // view putting back an old offset) goes back on it (D5)
        let movedByUser = !placing && (userIsScrolling || self.scrollView.isTracking || self.scrollView.isDragging
            || self.scrollView.isDecelerating || (isAutoScrolling && !autoScrollPausedForUserInteraction) || turningPage)
        let wasAt = anchorOffsetIntoChapter()
        if movedByUser {
            writeAnchorFromScreen()
        } else if !placing, !zoomView.isAnimatingZoom, applyAnchor() {
            return
        }
        let isAt = anchorOffsetIntoChapter()

        // the chapter is the anchor's: only the user moves it, so a layout never changes the chapter (SUWA-19)
        if infinite, let key = anchor?.chapterKey, let anchorIndex = chapters.firstIndex(where: { $0.key == key }) {
            if chapterIndex > 0 && anchorIndex < chapterIndex {
                movePreviousChapter()
                needsInfoRefresh = true
                pageReports.reset()
            } else if chapterIndex < chapters.count - 1 && anchorIndex > chapterIndex {
                moveNextChapter()
                needsInfoRefresh = true
                pageReports.reset()
            }
        }

        // up inside a chapter entered from below (SUWA-17 F3, G1): nothing is told; reading it going down is. Up
        // and down are the anchor's moves inside the chapter, not the offset's (a layout moves the offset: G2)
        let byDrag = !placing && (userIsScrolling || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating)
        if
            byDrag,
            let wasAt,
            let isAt,
            wasAt.chapterKey == isAt.chapterKey,
            isAt.chapterKey == self.chapter?.key
        {
            let offset = isAt.offset
            let goingUp = isAt.offset < wasAt.offset
            let goingDown = isAt.offset > wasAt.offset
            let height = collectionNode.bounds.height
            if let entry = enteredFromBelowAt, goingUp, offset < entry - height / 2 {
                enteredFromBelowAt = nil
                wentUpInside = (entry, offset)
                delegate?.movedUpIntoChapter()
            } else if let inside = wentUpInside {
                if goingUp {
                    wentUpInside?.highest = min(inside.highest, offset)
                } else if goingDown, inside.entry - inside.highest >= height - 1 {
                    wentUpInside = nil
                    pageReports.reset()
                }
            }
        }

        // the page is the anchor's: the content moving without the user tells nothing (SUWA-19); with it, where in
        // the page (D12), also when only that changes, but not inside a chapter entered from below (F3, G1: what
        // counts there is the next page)
        if let page = anchorPage() {
            let position = positionToReport(page: page)
            if pageReports.shouldReport(page) {
                reportedPosition = position
                delegate?.setCurrentPage(page, position: position)
            } else if
                let position,
                position != reportedPosition,
                enteredFromBelowAt == nil,
                wentUpInside == nil
            {
                reportedPosition = position
                delegate?.setCurrentPage(page, position: position)
            }
        }
        measureAhead()
    }

    // disable slider movement while zooming
    // zooming sometimes causes page count to jitter between two pages
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isZooming = true
        stopAutoScroll()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isZooming = false
        writeAnchorFromScreen()
        scrollViewDidScroll(scrollView)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Stop active scroll deceleration: the anchor is where the user was (SUWA-19; it is not taken here, so two
        // transitions one on top of the other keep the same one, as upstream #1116 wanted)
        let offset = scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: false)
        collectionNode.contentOffset = offset
        // the deceleration is cut without scrollViewDidEndDecelerating: the user is not scrolling any more, or what
        // UIKit moves after the size change would be taken as the user's (hallazgo 8)
        userIsScrolling = false

        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate { [weak self] _ in
            guard let self else { return }

            let isPortrait = size.height >= size.width
            pillarboxLayoutState.setIsPortrait(isPortrait)

            self.collectionNode.invalidateCalculatedLayout()
            self.collectionNode.collectionViewLayout.invalidateLayout()
            self.zoomView.adjustContentSize()
        } completion: { [weak self] _ in
            guard let self else { return }

            // on the anchor against the final bounds, rather than relying on the collection view to have asked for a
            // target offset (it may not, or may ask before the size settles)
            collectionNode.view.layoutIfNeeded()
            zoomView.adjustContentSize()
            applyAnchor()
        }
    }
}

// MARK: - Context Menu
extension ReaderWebtoonViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            case let point = interaction.location(in: collectionNode.view),
            let indexPath = collectionNode.indexPathForItem(at: point),
            let node = collectionNode.nodeForItem(at: indexPath) as? ReaderWebtoonPageNode,
            let image = node.imageNode.image,
            !AppSettings.dictionary.isReaderQuickActionsDisabled(language: node.page.language)
        else {
            return nil
        }
        // disable when live text highlighting is active
        if
            let imageAnalaysisInteraction = node.imageNode.imageAnalaysisInteraction,
            imageAnalaysisInteraction.selectableItemsHighlighted
        {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { [weak self] _ in
            guard let self else { return nil }

            let shareAction = UIAction(
                title: NSLocalizedString("SHARE"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                let items = [image]
                let activityController = UIActivityViewController(activityItems: items, applicationActivities: nil)

                activityController.popoverPresentationController?.sourceView = self.view
                activityController.popoverPresentationController?.sourceRect = CGRect(origin: location, size: .zero)

                self.present(activityController, animated: true)
            }

            let saveToPhotosAction = UIAction(
                title: NSLocalizedString("SAVE_TO_PHOTOS"),
                image: UIImage(systemName: "square.and.arrow.down")
            ) { _ in
                image.saveToAlbum(viewController: self)
            }

            let reloadAction = UIAction(
                title: NSLocalizedString("RELOAD"),
                image: UIImage(systemName: "arrow.clockwise")
            ) { _ in
                Task { @MainActor in
                    await self.reloadPageImage(for: node)
                }
            }

            return UIMenu(title: "", children: [shareAction, saveToPhotosAction, reloadAction])
        })
    }

    /// Reloads the page image for the given webtoon page node
    @MainActor
    private func reloadPageImage(for node: ReaderWebtoonPageNode) async {
        let success = await node.reloadCurrentImage()
        if !success {
            // Show error feedback if reload failed
            showReloadError()
        }
    }

    /// Shows an error message when image reload fails
    private func showReloadError() {
        let alert = UIAlertController(
            title: NSLocalizedString("RELOAD_FAILED"),
            message: NSLocalizedString("RELOAD_FAILED_TEXT"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Dictionary Lookup
extension ReaderWebtoonViewController: ReaderDictionaryReader {
    func recognizedText(at point: CGPoint) -> TextRecognizer.Result? {
        let collectionPoint = view.convert(point, to: collectionNode.view)
        guard
            let indexPath = collectionNode.indexPathForItem(at: collectionPoint),
            let node = collectionNode.nodeForItem(at: indexPath) as? ReaderWebtoonPageNode,
            let image = node.image,
            let recognizer = node.textRecognizer,
            let imageView = node.imageNode.imageView
        else {
            return nil
        }

        let localPoint = collectionNode.view.convert(collectionPoint, to: imageView)
        guard imageView.bounds.contains(localPoint) else { return nil }

        if var result = recognizer.findText(at: localPoint, in: imageView, imageSize: image.size) {
            result.charRect = imageView.convert(result.charRect, to: view)
            result.charRects = result.charRects.map { imageView.convert($0, to: view) }
            return result
        }
        return nil
    }

    func setDictionaryOverlayTapHandler(_ handler: ((String, String, CGRect, [CGRect]) -> Void)?) {
        dictionaryOverlayTapHandler = handler
    }

    func setDictionaryOverlayInteractionMode(_ mode: DictionaryOverlayInteractionMode) {
        dictionaryOverlayInteractionMode = mode
        for case let cell as ReaderWebtoonPageNode in collectionNode.visibleNodes {
            cell.setDictionaryOverlayInteractionMode(mode)
        }
    }

    func dismissActiveDictionaryOverlay() -> Bool {
        for case let node as ReaderWebtoonPageNode in collectionNode.visibleNodes where node.dismissActiveDictionaryOverlay() {
            return true
        }
        return false
    }

    private func forwardDictionaryOverlayTap(
        text: String,
        contextText: String,
        rect: CGRect,
        charRects: [CGRect],
        from imageView: UIImageView
    ) {
        let rectInView = imageView.convert(rect, to: view)
        let rectsInView = charRects.map { imageView.convert($0, to: view) }
        dictionaryOverlayTapHandler?(text, contextText, rectInView, rectsInView)
    }

    private func bindDictionaryOverlayTap(to cell: ReaderWebtoonPageNode) {
        cell.setDictionaryOverlayInteractionMode(dictionaryOverlayInteractionMode)
        cell.onDictionaryOverlayTap = { [weak self, weak cell] text, contextText, rect, charRects in
            guard let self, let imageView = cell?.imageNode.imageView else { return }
            self.forwardDictionaryOverlayTap(text: text, contextText: contextText, rect: rect, charRects: charRects, from: imageView)
        }
    }
}

// MARK: - Infinite Scroll
extension ReaderWebtoonViewController {

    // check for infinite load when deceleration stops
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if UserDefaults.standard.bool(forKey: "Reader.hideBarsOnSwipe") {
            delegate?.hideBars()
        }

        guard !decelerate else {
            return
        }
        userIsScrolling = false
        setLiveTextButtonHidden(false)

        if infinite {
            isScrolling = false
            checkInfiniteLoad()
        }
        resumeAutoScroll()
        updateContentScrollingState()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userIsScrolling = false
        setLiveTextButtonHidden(false)
        if infinite {
            isScrolling = false
            checkInfiniteLoad()
        }
        resumeAutoScroll()
        updateContentScrollingState()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        turningPage = false
        setLiveTextButtonHidden(false)
        if infinite {
            isScrolling = false
            checkInfiniteLoad()
        }
    }

    // check if at the top or bottom to append the next/prev chapter
    func checkInfiniteLoad() {
        // prepend previous chapter
        if !loadingPrevious {
            let topPath = getCurrentPagePath(pos: .top)
            if topPath == nil || (topPath?.section == 0 && topPath?.row == 0) {
                loadingPrevious = true
                Task {
                    await prependPreviousChapter()
                    loadingPrevious = false
                }
            }
        }
        // a missing path means the bottom of the screen is past the last page
        let bottomPath = getCurrentPagePath(pos: .bottom)

        // mark the current chapter completed at the end of its own section, which isn't
        // necessarily the last one now that the next chapter can be appended early
        if
            let chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let chapterPages = pages[safe: chapterIndex],
            case let end = chapterEndOnScreen(chapterIndex: chapterIndex, chapterPages: chapterPages, bottomPath: bottomPath),
            ReaderCompletion.webtoonReachedEnd(
                totalPages: end.totalPages,
                transitionFullyVisible: end.transitionFullyVisible,
                nextChapterLoaded: chapterIndex < chapters.count - 1,
                inForeground: UIApplication.shared.applicationState != .background
            )
        {
            if !journaledEnds.contains(chapter.key) {
                journaledEnds.insert(chapter.key)
                CompletionJournal.record(
                    .init(sourceKey: viewModel.manga.sourceKey, mangaKey: viewModel.manga.key, chapterKey: chapter.key),
                    reason: "webtoon: transición final",
                    detail: "abajo \(bottomPath.map { "\($0.section)/\($0.item)" } ?? "fuera"), capítulo \(chapterIndex) de \(pages.count) "
                        + "con \(chapterPages.count), desplazamiento \(Int(collectionNode.contentOffset.y)), alto \(Int(collectionNode.bounds.height)), "
                        + "contenido \(Int(collectionNode.view.contentSize.height)), zoom \(scrollView.zoomScale), "
                        + "página visible \(end.maxVisiblePage ?? 0) de \(end.totalPages), transición entera \(end.transitionFullyVisible)"
                )
            }
            delegate?.setCompleted()
        }

        if !loadingNext {
            let lastSection = pages.count - 1
            let lastItem = (pages.last?.count ?? 0) - 1
            let atEnd = bottomPath == nil || (bottomPath?.section == lastSection && bottomPath?.item == lastItem)
            // append the next chapter before reaching the end, so its pages have time to load
            let withinPreloadRange = bottomPath?.section == lastSection
                && lastItem - (bottomPath?.item ?? lastItem) <= pagesToPreload

            if atEnd || withinPreloadRange {
                loadingNext = true
                Task {
                    await appendNextChapter()
                    loadingNext = false
                }
            }
        }
    }

    /// What of the chapter is on screen: the page under the bottom edge, the last page visible and whether
    /// the transition after its last page is entirely on screen (SUWA-17).
    private func chapterEndOnScreen(
        chapterIndex: Int,
        chapterPages: [Page],
        bottomPath: IndexPath?
    ) -> (bottomEdgePage: Int?, maxVisiblePage: Int?, totalPages: Int, transitionFullyVisible: Bool) {
        let hasStartInfo = chapterPages.first?.type != .imagePage
        let hasEndInfo = chapterPages.last?.type != .imagePage
        let offset = hasStartInfo ? 0 : 1
        let totalPages = chapterPages.filter { $0.type == .imagePage }.count
        let visible = collectionNode.indexPathsForVisibleItems.filter { $0.section == chapterIndex }.map(\.item)
        let maxVisiblePage = visible.filter { chapterPages[safe: $0]?.type == .imagePage }.max().map { $0 + offset }
        let viewport = CGRect(origin: collectionNode.contentOffset, size: collectionNode.bounds.size)
        let transitionFrame = collectionNode.collectionViewLayout
            .layoutAttributesForItem(at: IndexPath(item: chapterPages.count - 1, section: chapterIndex))?.frame
        let transitionFullyVisible = hasEndInfo && visible.contains(chapterPages.count - 1)
            && transitionFrame.map { $0.height > 0 && $0.minY >= viewport.minY - 1 && $0.maxY <= viewport.maxY + 1 } ?? false
        let bottomEdgePage = bottomPath.map { $0.section == chapterIndex ? $0.item + offset : 0 }
        return (bottomEdgePage, maxVisiblePage, totalPages, transitionFullyVisible)
    }

    /// Prepend the previous chapter's pages
    func prependPreviousChapter() async {
        guard let prevChapter = delegate?.getPreviousChapter() else { return }
        guard !chapters.contains(prevChapter) else { return }
        // hold our own reference
        let preloadedPages = await viewModel.preload(chapter: prevChapter)

        // check if pages failed to load
        if preloadedPages.isEmpty {
            return
        }

        // wait until zooming and scrolling stops
        while isZooming || isScrolling {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        var chapterPages = [Page(
            type: .prevInfoPage,
            sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
            chapterId: prevChapter.key,
            index: -1
        )] + preloadedPages
        // A trimmed chapter may have owned the separator before the retained neighbor.
        if pages.first?.first?.type == .imagePage {
            chapterPages.append(Page(
                type: .nextInfoPage,
                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
                chapterId: prevChapter.key,
                index: -2
            ))
        }
        chapters.insert(prevChapter, at: 0)
        pages.insert(chapterPages, at: 0)

        // disable animations and adjust offset before re-enabling (the layout keeps the anchor: SUWA-19)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        await collectionNode.performBatch(animated: false) {
            collectionNode.insertSections(IndexSet(integer: 0))
        }

        // settle the insert's offset adjustment before the trim changes the content size
        collectionNode.view.layoutIfNeeded()

        // trim the newest section once the window is full
        let trimIndex = pages.count - 1
        if !loadingNext, canTrimSection(at: trimIndex) {
            chapters.removeLast()
            pages.removeLast()
            await collectionNode.performBatch(animated: false) {
                collectionNode.deleteSections(IndexSet(integer: trimIndex))
            }
        }

        self.scrollView.contentOffset = self.collectionNode.contentOffset
        self.zoomView.adjustContentSize()
        CATransaction.commit()
    }

    /// Append the next chapter's pages
    func appendNextChapter() async {
        guard let nextChapter = delegate?.getNextChapter() else { return }
        guard !chapters.contains(nextChapter) else { return }
        let preloadedPages = await viewModel.preload(chapter: nextChapter)

        // check if pages failed to load
        if preloadedPages.isEmpty {
            return
        }

        // wait until zooming and scrolling stops
        while isZooming || isScrolling {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        var chapterPages = preloadedPages + [Page(
            type: .nextInfoPage,
            sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
            chapterId: nextChapter.id,
            index: -2
        )]
        // A trimmed chapter may have owned the separator after the retained neighbor.
        if pages.last?.last?.type == .imagePage {
            chapterPages.insert(Page(
                type: .prevInfoPage,
                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
                chapterId: nextChapter.key,
                index: -1
            ), at: 0)
        }
        chapters.append(nextChapter)
        pages.append(chapterPages)

        // disable animations and adjust offset before re-enabling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        await collectionNode.performBatch(animated: false) {
            collectionNode.insertSections(IndexSet(integer: pages.count - 1))
        }

        collectionNode.view.layoutIfNeeded()

        if !loadingPrevious, canTrimSection(at: 0) {
            // the anchor is by chapter: its section index changing moves nothing (SUWA-19)
            chapters.removeFirst()
            pages.removeFirst()
            await collectionNode.performBatch(animated: false) {
                collectionNode.deleteSections(IndexSet(integer: 0))
            }
        }

        scrollView.contentOffset = self.collectionNode.contentOffset
        zoomView.adjustContentSize()
        CATransaction.commit()
    }

    /// Switch current chapter to previous
    func movePreviousChapter() {
        guard
            let currChapter = chapter,
            let chapterIndex = chapters.firstIndex(of: currChapter),
            let chapter = chapters[safe: chapterIndex - 1],
            let pages = pages[safe: chapterIndex - 1]
        else { return }
        self.chapter = chapter
        updateDoubleTapZoomSetting()
        delegate?.setChapter(chapter)
        delegate?.setPages(pages.filter({ $0.type == .imagePage }))
        viewModel.setPages(chapter: chapter, pages: pages)
        enteredFromBelowAt = anchorOffsetIntoChapter().flatMap { $0.chapterKey == chapter.key ? $0.offset : nil }
        wentUpInside = nil
    }

    /// The app going out of front and coming back (SUWA-17 H). Out of front, iPadOS lays the app out again at
    /// other sizes (the app switcher, Stage Manager, a window) and the anchor does not move (only the user moves
    /// it, with the app in front): back in front, the screen is put on it (SUWA-19).
    func appActivityChanged(active: Bool) {
        guard active else { return }
        collectionNode.view.layoutIfNeeded()
        applyAnchor()
    }

    /// Puts the screen (both scroll views) where the anchor goes with the layout as it is. False if it was there
    /// already or there is no anchor to put it on.
    @discardableResult
    func applyAnchor() -> Bool {
        guard
            !applyingAnchor,
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout,
            let target = layout.anchorOffset()
        else { return false }
        guard abs(target.y - collectionNode.contentOffset.y) > 0.5 || abs(target.y - scrollView.contentOffset.y) > 0.5 else {
            return false
        }
        applyingAnchor = true
        defer { applyingAnchor = false }
        zoomView.adjustContentSize()
        let offset = CGPoint(x: scrollView.contentOffset.x, y: target.y)
        scrollView.setContentOffset(offset, animated: false)
        collectionNode.contentOffset = offset
        return true
    }

    /// How far the top of the screen is into the anchor's chapter when the screen is on the anchor, with the
    /// layout as it is (SUWA-19; before, the screen's own offset into the current chapter).
    private func anchorOffsetIntoChapter() -> (chapterKey: String, offset: CGFloat)? {
        guard
            let anchor,
            let section = chapters.firstIndex(where: { $0.key == anchor.chapterKey }),
            let top = collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame.minY,
            let frame = collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: anchor.item, section: section))?.frame
        else { return nil }
        let point = frame.minY + frame.height * anchor.fraction
        return (anchor.chapterKey, point - anchor.screenFraction * collectionNode.bounds.height - top)
    }

    /// Switch current chapter to next
    func moveNextChapter() {
        guard
            let currChapter = chapter,
            let chapterIndex = chapters.firstIndex(of: currChapter),
            let chapter = chapters[safe: chapterIndex + 1],
            let pages = pages[safe: chapterIndex + 1]
        else { return }
        self.chapter = chapter
        updateDoubleTapZoomSetting()
        delegate?.setChapter(chapter)
        delegate?.setPages(pages.filter({ $0.type == .imagePage }))
        viewModel.setPages(chapter: chapter, pages: pages)
        enteredFromBelowAt = nil
        wentUpInside = nil
    }

    /// Refresh info page chapter info
    func refreshInfoPages() {
        let paths = pages.enumerated().flatMap { section, pages in
            pages.enumerated().compactMap { item, page in
                if page.type != .imagePage {
                    return IndexPath(item: item, section: section)
                } else {
                    return nil
                }
            }
        }
        collectionNode.performBatchUpdates {
            collectionNode.reloadItems(at: paths)
        } completion: { finished in
            if finished {
                Task { @MainActor in
                    self.zoomView.adjustContentSize()
                }
            }
        }
    }
}

// MARK: - Reader Delegate
extension ReaderWebtoonViewController: ReaderReaderDelegate {
    func moveLeft() {
        let offset = CGPoint(
            x: collectionNode.contentOffset.x,
            y: max(
                0,
                collectionNode.contentOffset.y - collectionNode.bounds.height * 2/3
            )
        )
        let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        turningPage = offset != scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: animated)
        if !animated {
            turningPage = false
        }
    }

    func moveRight() {
        let offset = CGPoint(
            x: collectionNode.contentOffset.x,
            y: min(
                scrollView.contentSize.height - scrollView.bounds.height,
                collectionNode.contentOffset.y + collectionNode.bounds.height * 2/3
            )
        )
        let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        turningPage = offset != scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: animated)
        if !animated {
            turningPage = false
        }
    }

    func sliderMoved(value: CGFloat) {
        isSliding = true

        // get slider area
        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let layout = self.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout,
            let currentPages = pages[safe: chapterIndex]
        else { return }

        var offset: CGFloat = 0
        for idx in 0..<chapterIndex {
            offset += layout.getHeightFor(section: idx)
        }

        let hasStartInfo = currentPages.first?.type != .imagePage
        let hasEndInfo = currentPages.last?.type != .imagePage

        if hasStartInfo {
            offset += layout.getHeightFor(section: chapterIndex, range: 0..<1)
        }

        let height = max(
            0,
            layout.getHeightFor(
                section: chapterIndex,
                range: (hasStartInfo ? 1 : 0)..<currentPages.count - (hasEndInfo ? 1 : 0)
            ) - collectionNode.bounds.height
        )

        scrollView.setContentOffset(
            CGPoint(x: collectionNode.contentOffset.x, y: offset + height * value),
            animated: false
        )

        // the slider is the user moving (SUWA-19)
        writeAnchorFromScreen()
        let page = getCurrentPage()
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        isSliding = false
        writeAnchorFromScreen()
        scrollViewDidScroll(collectionNode.view)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        // the pages of the chapters shown stop loading and being measured (SUWA-17 E2)
        for (section, sectionPages) in pages.enumerated() {
            for item in sectionPages.indices {
                (collectionNode.nodeForItem(at: IndexPath(item: item, section: section)) as? ReaderWebtoonPageNode)?.stopLoading()
            }
        }
        decodeWindow.removeAllObjects()
        decodeLeaving.removeAllObjects()
        decodeWindowIDs.set([])
        measureWanted.removeAllObjects()
        measureWantedIDs.set([])
        measuredAheadFrom = nil
        self.chapter = chapter
        // a new chapter: its first page is reported even if it has the number the last one had
        pageReports.reset()
        enteredFromBelowAt = nil
        wentUpInside = nil
        anchor = nil
        anchorIsTheUsers = false
        reportedPosition = nil
        let openingFraction = openingFraction
        self.openingFraction = nil
        updateDoubleTapZoomSetting()
        chapters = [chapter]

        Task {
            await viewModel.loadPages(chapter: chapter)
            delegate?.setPages(viewModel.pages)
            if viewModel.pages.isEmpty {
                pages = []
                await collectionNode.reloadData()
                return
            }
            let sourceId = viewModel.source?.key ?? viewModel.manga.sourceKey
            pages = [[
                Page(
                    type: .prevInfoPage,
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    index: -1
                )
            ] + viewModel.pages + [
                Page(
                    type: .nextInfoPage,
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    index: -2
                )
            ]]

            var startPage = startPage
            if startPage < 1 {
                startPage = 1
            } else if startPage > viewModel.pages.count {
                startPage = viewModel.pages.count
            }

            // the top of the page it opens at, at the top of the screen (SUWA-19 D4); with a saved fraction, that
            // point of the page in the middle of the screen (D12)
            anchor = if let openingFraction {
                ReadingAnchor(chapterKey: chapter.key, item: startPage, fraction: CGFloat(openingFraction), screenFraction: 0.5, measured: true)
            } else {
                ReadingAnchor(chapterKey: chapter.key, item: startPage, fraction: 0, screenFraction: 0, measured: true)
            }
            await collectionNode.reloadData()
            zoomView.adjustContentSize()

            // scroll to first page
            collectionNode.scrollToItem(
                at: IndexPath(row: startPage, section: 0),
                at: .top,
                animated: false
            )
            scrollView.contentOffset = collectionNode.contentOffset
            if openingFraction != nil {
                applyAnchor()
            }
        }
    }
}

// MARK: - Collection View Delegate
extension ReaderWebtoonViewController: ASCollectionDelegate {

    // The pages after the screen are measured as soon as the first ones show (opening, a new chapter)
    func collectionNode(_ collectionNode: ASCollectionNode, willDisplayItemWith node: ASCellNode) {
        measureAhead()
    }

    // Refresh info pages after they move off screen
    func collectionNode(_ collectionNode: ASCollectionNode, didEndDisplayingItemWith node: ASCellNode) {
        guard needsInfoRefresh else { return }
        if node is ReaderWebtoonTransitionNode {
            needsInfoRefresh = false
            refreshInfoPages()
        }
    }
}

// MARK: - Data Source
extension ReaderWebtoonViewController: ASCollectionDataSource {

    func numberOfSections(in collectionNode: ASCollectionNode) -> Int {
        pages.count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        numberOfItemsInSection section: Int
    ) -> Int {
        pages[section].count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        nodeBlockForItemAt indexPath: IndexPath
    ) -> ASCellNodeBlock {
        guard let chapter else { return { ASCellNode() } }
        var page = pages[indexPath.section][indexPath.item]
        if page.type == .imagePage {
            // image page
            let imageSettings = ReaderWebtoonPageNode.ImageSettings.current
            return { [weak self] in
                guard
                    let self,
                    let temporaryPageStore = self.viewModel.temporaryPageStore
                else {
                    return ASCellNode()
                }
                let cell = ReaderWebtoonPageNode(
                    source: self.viewModel.source,
                    page: page,
                    temporaryPageStore: temporaryPageStore,
                    pillarboxLayoutState: self.pillarboxLayoutState,
                    imageSettings: imageSettings
                )
                cell.delegate = self
                self.bindDictionaryOverlayTap(to: cell)
                return cell
            }
        } else {
            // transition page
            let chapterIndex = chapters.firstIndex(of: chapter) ?? 0

            // determine page type
            if (indexPath.section == chapterIndex && indexPath.item == 0)
                || (indexPath.section == chapterIndex - 1 && indexPath.item > 0) {
                page.type = .prevInfoPage
            } else {
                page.type = .nextInfoPage
            }

            let to = page.type == .prevInfoPage
                ? self.delegate?.getPreviousChapter()
                : self.delegate?.getNextChapter()
            return {
                ReaderWebtoonTransitionNode(
                    transition: .init(
                        type: page.type == .prevInfoPage ? .prev : .next,
                        from: chapter,
                        to: to
                    ),
                    pillarboxLayoutState: self.pillarboxLayoutState
                )
            }
        }
    }
}

/// The pages of the webtoon reader that may hold a decoded image now (SUWA-17 E1), asked by the pages from their
/// own callbacks.
final class ReaderDecodeWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: Set<ObjectIdentifier> = []

    func contains(_ node: AnyObject) -> Bool {
        lock.withLock { nodes.contains(ObjectIdentifier(node)) }
    }

    func set(_ nodes: [AnyObject]) {
        let ids = Set(nodes.map { ObjectIdentifier($0) })
        lock.withLock { self.nodes = ids }
    }
}
