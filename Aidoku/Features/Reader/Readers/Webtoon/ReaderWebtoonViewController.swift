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
    /// The pages that may hold a decoded image: from the first one on screen, «pages to preload» + 2 in all
    /// counting the ones on screen (all of these if more show at once). Texture's preload range alone loads
    /// and decodes as far as 2.5 screens below (SUWA-17 E1).
    private let decodeWindow = NSHashTable<ReaderWebtoonPageNode>.weakObjects()
    /// The pages out of it that could not let go of their image yet (on screen for Texture a moment longer).
    private let decodeLeaving = NSHashTable<ReaderWebtoonPageNode>.weakObjects()
    private var loadingNext = false

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
    // How many size transitions haven't completed yet, so overlapping ones share the first anchor (upstream #1116)
    private var pendingSizeTransitions = 0
    private(set) var isContentScrolling = false {
        didSet {
            guard isContentScrolling != oldValue else { return }
            onContentScrollingChange?(isContentScrolling)
        }
    }

    // Stores the last calculated page number
    /// Reports only real page changes, and the first page of each chapter.
    private var pageReports = PageReportFilter()
    /// The page the chapter opened at, reported as the current page until the user moves (drag, slider, tap or
    /// key navigation, auto scroll, zoom). Opening puts that page at the top; the pages above it then grow as
    /// their images load and move the content, and the page in the middle of the screen becomes the one
    /// before: that is not the user reading, so it is neither reported nor saved. SUWA-16
    private var openingPageHold: Int?
    /// Where the user is reading (SUWA-19): only the user moves it, and opening a chapter.
    private(set) var anchor: ReadingAnchor?
    /// Entering the previous chapter from below by scrolling: how far into its section the screen was. Once the
    /// user goes half a screen further up inside it, they are reading it (SUWA-17 F3: a chapter of one page, or a
    /// last page taller than the screen, has no page before the last to report).
    private var enteredFromBelowAt: CGFloat?
    /// After going up inside it: where the user entered and the highest point they went up to. Going down after
    /// going a whole screen above where they entered is reading it: its page is told again (SUWA-17 G1).
    private var wentUpInside: (entry: CGFloat, highest: CGFloat)?
    private var lastScrollOffset: CGFloat = 0
    /// The user is dragging the content, or it decelerates after their drag: not the layout moving it (SUWA-17 G2).
    private var userIsScrolling = false
    /// Turning a page (tap, key): its scroll may take the reader into another chapter (SUWA-17 H).
    private var turningPage = false
    /// Out of front: the page in the middle of the screen when the app left, where in it the middle was and the
    /// layout's width changes then; back in front after the width changed, it is put back (SUWA-17 H).
    private var leftFront: (chapter: AidokuRunner.Chapter, item: Int, fraction: CGFloat, widthChanges: Int)?
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

    override func configure() {
        super.configure()

        collectionNode.delegate = self
        collectionNode.dataSource = self
//        collectionNode.view.prefetchDataSource = self
//        collectionNode.isPrefetchingEnabled = true

        // override texture's automatic decreased preloading range
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .minimum, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .minimum, rangeType: .preload)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .lowMemory, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .lowMemory, rangeType: .preload)

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
        var window: [ReaderWebtoonPageNode] = []
        var count = 0
        var path: IndexPath? = first
        while let current = path, count < max(0, pagesToPreload) + 2 || current <= last {
            if let node = collectionNode.nodeForItem(at: current) as? ReaderWebtoonPageNode {
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
        openingPageHold = nil

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
        openingPageHold = nil
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

        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter)
        else { return }

        // UIKit scales the offset by the content's size right after a width change, on top of the layout keeping
        // the middle page: back to where the layout put it (SUWA-17 H)
        if
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout,
            let kept = layout.widthChangeOffset,
            abs(collectionNode.contentOffset.y - kept.y) > 0.5
        {
            collectionNode.contentOffset = kept
            self.scrollView.contentOffset = kept
            return
        }

        let pagePath = getCurrentPagePath()

        // The chapter changes only when the user moves the content (dragging and its deceleration, the auto
        // scroll, turning a page), with the app in front and a page in the middle of the screen: never by a layout
        // pass (the window's width changing: iPadOS lays the app out again out of front, for the app switcher or
        // Stage Manager), nor by nothing being in the middle (that was section 0) (SUWA-17 H)
        let movedByUser = userIsScrolling || self.scrollView.isTracking || self.scrollView.isDragging
            || self.scrollView.isDecelerating || (isAutoScrolling && !autoScrollPausedForUserInteraction) || turningPage
        if infinite, let pageSection = pagePath?.section, movedByUser, delegate?.appActivity.isActive ?? true {
            // check if we need to switch chapters
            if chapterIndex > 0 && pageSection < chapterIndex {
                movePreviousChapter()
                needsInfoRefresh = true
                pageReports.reset()
            } else if chapterIndex < chapters.count - 1 {
                if pageSection > chapterIndex {
                    moveNextChapter()
                    needsInfoRefresh = true
                    pageReports.reset()
                }
            }
        }

        // up inside a chapter entered from below (SUWA-17 F3, G1): nothing is told; reading it going down is
        let offsetY = collectionNode.contentOffset.y
        let goingUp = offsetY < lastScrollOffset
        let goingDown = offsetY > lastScrollOffset
        lastScrollOffset = offsetY
        let byUser = userIsScrolling || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if byUser, let offset = offsetIntoChapter() {
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

        // update page number (the opening page until the user moves); nothing in the middle of the screen: no page
        if let page = openingPageHold ?? (pagePath == nil ? nil : getCurrentPage()), pageReports.shouldReport(page) {
            delegate?.setCurrentPage(page, position: nil)
        }
        measureAhead()
    }

    // disable slider movement while zooming
    // zooming sometimes causes page count to jitter between two pages
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        openingPageHold = nil
        isZooming = true
        stopAutoScroll()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isZooming = false
        scrollViewDidScroll(scrollView)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Stop active scroll deceleration before capturing the rotation anchor.
        let offset = scrollView.contentOffset
        scrollView.setContentOffset(offset, animated: false)
        collectionNode.contentOffset = offset

        let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
        // a transition that starts before the last one completes would capture an in-between position
        // (switching apps on iPhone Duo resizes twice in quick succession)
        if pendingSizeTransitions == 0 {
            layout?.preserveVisiblePosition()
        }
        pendingSizeTransitions += 1

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

            // restore the anchor against the final bounds, rather than relying on the collection view
            // to have asked for a target offset (it may not, or may ask before the size settles)
            collectionNode.view.layoutIfNeeded()
            let offset = layout?.preservedContentOffset() ?? collectionNode.contentOffset
            pendingSizeTransitions -= 1
            if pendingSizeTransitions == 0 {
                layout?.clearPreservedPosition()
            }
            zoomView.adjustContentSize()
            scrollView.contentOffset = offset
            collectionNode.contentOffset = offset
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

        let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
        layout?.preserveOffsetAcrossChangeAbove()

        // disable animations and adjust offset before re-enabling
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
            // preserve the visible cell as its section index changes
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
            layout?.preserveOffsetAcrossChangeAbove()
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
        enteredFromBelowAt = offsetIntoChapter()
        wentUpInside = nil
    }

    /// The app going out of front and coming back (SUWA-17 H). Out of front, iPadOS lays the app out again at
    /// other sizes (the app switcher, Stage Manager, a window): back in front after the width changed, the page
    /// that was in the middle of the screen is put back there, at the same place inside it.
    func appActivityChanged(active: Bool) {
        guard let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout else { return }
        guard active else {
            guard
                let path = getCurrentPagePath(),
                let chapter = chapters[safe: path.section],
                let frame = layout.layoutAttributesForItem(at: path)?.frame, frame.height > 0
            else {
                leftFront = nil
                return
            }
            let middle = collectionNode.contentOffset.y + collectionNode.bounds.height / 2
            leftFront = (chapter, path.item, (middle - frame.minY) / frame.height, layout.widthChanges)
            return
        }
        guard let left = leftFront else { return }
        leftFront = nil
        guard
            left.widthChanges != layout.widthChanges,
            let section = chapters.firstIndex(of: left.chapter),
            let frame = layout.layoutAttributesForItem(at: IndexPath(item: left.item, section: section))?.frame
        else { return }
        zoomView.adjustContentSize()
        let height = collectionNode.bounds.height
        let maxY = max(0, layout.collectionViewContentSize.height - height)
        let y = min(max(frame.minY + frame.height * left.fraction - height / 2, 0), maxY)
        guard abs(y - collectionNode.contentOffset.y) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
        collectionNode.contentOffset = scrollView.contentOffset
    }

    /// How far the top of the screen is into the current chapter's section.
    private func offsetIntoChapter() -> CGFloat? {
        guard
            let chapter,
            let section = chapters.firstIndex(of: chapter),
            let top = collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame.minY
        else { return nil }
        return collectionNode.contentOffset.y - top
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
        openingPageHold = nil
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
        openingPageHold = nil
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
        openingPageHold = nil
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

        let page = getCurrentPage()
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        isSliding = false
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
        openingPageHold = nil
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

            openingPageHold = startPage
            await collectionNode.reloadData()
            zoomView.adjustContentSize()

            // scroll to first page
            collectionNode.scrollToItem(
                at: IndexPath(row: startPage, section: 0),
                at: .top,
                animated: false
            )
            scrollView.contentOffset = collectionNode.contentOffset
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
