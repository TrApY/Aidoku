//
//  ReaderWebtoonAnchorLayoutTests.swift
//  AidokuTests
//
//  SUWA-19 revisión (W6), hallazgo 4: the anchor against real relayouts, on screen. The images come from a loader
//  that holds the pages the test says until it lets them go, so cells grow (or shrink) when the test wants: above
//  the screen, at the anchor, during a drag or a deceleration, inside a chapter entered from below. Through the real
//  ReaderViewController and webtoon reader. Most of these protect what the anchor already does (born green, as the
//  spec foresaw); what each one checks is the anchor's point on screen, not only the anchor's fields.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Nuke
import Testing
import UIKit

@testable import Aidoku

/// Serves the page files at once, except the ones `holding` says: those wait until `release()`.
final class HeldImageLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var holding: @Sendable (String) -> Bool
    private var held: [DispatchWorkItem] = []

    init(holding: @escaping @Sendable (String) -> Bool) {
        self.holding = holding
    }

    /// The held pages come, and nothing is held from now on.
    func release() {
        lock.lock()
        let items = held
        held = []
        holding = { _ in false }
        lock.unlock()
        for item in items {
            DispatchQueue.global().async(execute: item)
        }
    }

    private final class Work: Cancellable, @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) {
            self.item = item
        }
        func cancel() {
            item.cancel()
        }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let path = request.url?.path ?? ""
        let item = DispatchWorkItem {
            guard let url = request.url, let data = try? Data(contentsOf: URL(fileURLWithPath: url.path)) else {
                completion(URLError(.cannotOpenFile))
                return
            }
            didReceiveData(data, URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
            completion(nil)
        }
        lock.lock()
        if holding(path) {
            held.append(item)
            lock.unlock()
            return Work(item)
        }
        lock.unlock()
        DispatchQueue.global().async(execute: item)
        return Work(item)
    }
}

extension ImagePipelineSwappingTests {
@MainActor
@Suite(.serialized) struct ReaderWebtoonAnchorLayoutTests {
    private static let pageCount = 12

    /// Chapter 2's pages are tall (300×900 and 300×860: about 1200 pt on screen, the provisional height is ~577);
    /// chapter 1's are short (300×100: ~134 pt), so they shrink when they come (by more than a screen, three of them).
    /// SUWA-39 R2: `count` pages, of the size `size` says (nil: as above).
    private static func pages(
        sourceKey: String,
        chapterKey: String,
        in directory: URL,
        count: Int = pageCount,
        size customSize: (@Sendable (String, Int) -> CGSize)? = nil
    ) throws -> [Aidoku.Page] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<count {
            let size = customSize?(chapterKey, index)
                ?? CGSize(width: 300, height: chapterKey == "c1" ? 100 : (index % 2 == 0 ? 900 : 860))
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let url = directory.appendingPathComponent("\(chapterKey)-\(index).png")
            try data.write(to: url)
            pages.append(Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, imageURL: SlowImageLoader.serverURL(url)))
        }
        return pages
    }

    @MainActor
    private struct Opened {
        let reader: ReaderViewController
        let webtoon: ReaderWebtoonViewController
        let ids: [ChapterIdentifier]
        let window: UIWindow
        let center: NotificationCenter
        let directory: URL
        let modeKey: String
        let pipeline: ImagePipeline
        let loader: HeldImageLoader
        /// The manga's chapters, oldest first, as the reader has them (SUWA-39).
        let chain: [AidokuRunner.Chapter]
        let sourceKey: String
        /// How many pages each chapter has and the size of them (nil: the default ones) (SUWA-39 R2).
        var pageCount = ReaderWebtoonAnchorLayoutTests.pageCount
        var pageSize: (@Sendable (String, Int) -> CGSize)?

        func close() async {
            window.isHidden = true
            loader.release()
            ImagePipeline.shared = pipeline
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
            for id in ids {
                await removeTestHistory(id)
            }
        }

        var sections: Int { webtoon.collectionNode.numberOfSections }

        func frame(row: Int, section: Int) throws -> CGRect {
            try #require(webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: section))?.frame)
        }

        /// Where the anchor's point is on the screen against where it should be (0: in its place).
        func distanceFromTheAnchor() throws -> CGFloat {
            let anchor = try #require(webtoon.anchor, "no anchor")
            // the section of the anchor's chapter in the reader's own list (with two chapters, c1 above c2)
            let section = webtoon.chapters.firstIndex { $0.key == anchor.chapterKey } ?? 0
            let frame = try frame(row: anchor.item, section: section)
            let point = frame.minY + frame.height * anchor.fraction - webtoon.collectionNode.contentOffset.y
            return point - anchor.screenFraction * webtoon.collectionNode.bounds.height
        }

        /// Both scroll views (the zoom's and the collection's) have the same offset (I9).
        var scrollViewsAgree: Bool {
            abs(webtoon.scrollView.contentOffset.y - webtoon.collectionNode.contentOffset.y) < 0.5
        }
    }

    /// Opens chapter 2 ("c2", with "c1" before it) at `startPage`; the pages whose file name `holding` says wait.
    /// SUWA-39: `chain` (oldest first) and `startKey` open another chapter of a longer manga (its pages all tall).
    private func open(
        mangaKey: String,
        startPage: Int,
        holding: @escaping @Sendable (String) -> Bool,
        chain keys: [String] = ["c1", "c2"],
        startKey: String = "c2",
        windowSize: CGSize = CGSize(width: 402, height: 874),
        pageCount: Int = ReaderWebtoonAnchorLayoutTests.pageCount,
        pageSize: (@Sendable (String, Int) -> CGSize)? = nil
    ) async throws -> Opened {
        let chain = keys.enumerated().map { AidokuRunner.Chapter(key: $0.element, chapterNumber: Float($0.offset + 1)) }
        let startIndex = try #require(keys.firstIndex(of: startKey))
        let chapter = chain[startIndex]
        let previous = chain[safe: startIndex - 1]
        let manga = AidokuRunner.Manga(sourceKey: "lectoranclalayout", key: mangaKey, title: "Webtoon", chapters: Array(chain.reversed()))
        let ids = chain.map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key) }
        for id in ids {
            await removeTestHistory(id)
        }
        await DataRepositories.shared.history.savePage(PageSave(chapter: ids[startIndex], page: startPage, totalPages: pageCount))
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anclalayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key, in: directory, count: pageCount, size: pageSize)
        let previousPages = try previous.map {
            try Self.pages(sourceKey: manga.sourceKey, chapterKey: $0.key, in: directory, count: pageCount, size: pageSize)
        } ?? []

        let pipeline = ImagePipeline.shared
        let loader = HeldImageLoader { path in holding((path as NSString).lastPathComponent) }
        ImagePipeline.shared = ImagePipeline {
            $0.dataLoader = loader
            $0.isLocalResourcesSupportEnabled = false
            $0.imageCache = nil
        }
        let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
        let center = NotificationCenter()
        reader.appActivity = ReaderAppActivity(center: center, active: true)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: windowSize)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let webtoon = try #require(reader.reader as? ReaderWebtoonViewController, "not the webtoon reader")
        reader.presentedViewController?.dismiss(animated: false)
        webtoon.viewModel.preloadedChapter = chapter
        webtoon.viewModel.preloadedPages = pages
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(3))
        webtoon.viewModel.preloadedChapter = previous
        webtoon.viewModel.preloadedPages = previousPages
        return Opened(
            reader: reader, webtoon: webtoon, ids: ids, window: window, center: center, directory: directory, modeKey: modeKey,
            pipeline: pipeline, loader: loader, chain: chain, sourceKey: manga.sourceKey, pageCount: pageCount, pageSize: pageSize
        )
    }

    /// Chapter 2's file of page index `index` (row index + 1).
    private static func c2(_ indices: Range<Int>) -> @Sendable (String) -> Bool {
        { name in indices.contains(where: { name == "c2-\($0).png" }) }
    }

    private static let allOfC1: @Sendable (String) -> Bool = { $0.hasPrefix("c1-") }

    /// The user drags until the middle of the screen is at `fraction` of `row` of `section`, and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int, section: Int, at fraction: CGFloat = 0.5, decelerating: Bool = false) throws {
        let webtoon = opened.webtoon
        let frame = try opened.frame(row: row, section: section)
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: frame.minY + frame.height * fraction - webtoon.collectionNode.bounds.height / 2), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: decelerating)
    }

    /// Waits (up to `seconds`) until `condition` holds: the held pages come when the reader asks for them again,
    /// which under the whole suite's load can take longer than a fixed wait.
    private func waitUntil(seconds: Double = 8, _ condition: () throws -> Bool) async throws {
        let start = ContinuousClock.now
        while try !condition(), ContinuousClock.now - start < .milliseconds(Int(seconds * 1000)) {
            try await Task.sleep(for: .milliseconds(250))
        }
        // and the layout settles
        try await Task.sleep(for: .milliseconds(500))
    }

    /// Up to chapter 2's transition: chapter 1 goes in above (its pages as `open` held them).
    private func putThePreviousChapterIn(_ opened: Opened) async throws {
        if opened.sections < 2 {
            try userScrolls(opened, toRow: 0, section: 0, at: 0.6)
            try await Task.sleep(for: .seconds(3))
        }
        if opened.sections < 2 {
            opened.webtoon.scrollViewWillBeginDragging(opened.webtoon.scrollView)
            opened.webtoon.scrollViewDidEndDragging(opened.webtoon.scrollView, willDecelerate: false)
        }
        for _ in 0..<24 where opened.sections < 2 {
            try await Task.sleep(for: .milliseconds(250))
        }
        try #require(opened.sections == 2, "chapter 1 did not go in above")
        try await Task.sleep(for: .seconds(1))
    }

    // MARK: - Paso 3

    /// SUWA-16's visible part: opened at page 8, the pages above come after it and grow: the top of page 8 is
    /// still at the top of the screen (before, the end of page 7 showed there).
    @Test func reopeningShowsTheTopOfTheStartPageAfterThePagesAboveLoad() async throws {
        let opened = try await open(mangaKey: "reabrirarriba", startPage: 8, holding: Self.c2(0..<7))
        let before = try opened.frame(row: 7, section: 0).height
        opened.loader.release()
        try await waitUntil { try opened.frame(row: 7, section: 0).height > before + 100 }
        try #require(try opened.frame(row: 7, section: 0).height > before + 100, "page 7 did not grow")
        let top = try opened.frame(row: 8, section: 0).minY - opened.webtoon.collectionNode.contentOffset.y
        #expect(abs(top) < 0.5, "the top of page 8 is \(top) pt from the top of the screen")
        #expect(opened.scrollViewsAgree)
        await opened.close()
    }

    /// I2: the user reads page 8 at 37 %; the pages above come and grow: the anchor's point stays on the anchor's
    /// line, to half a point.
    @Test func pagesAboveGrowingKeepTheAnchorExactly() async throws {
        let opened = try await open(mangaKey: "crecenarriba", startPage: 8, holding: Self.c2(0..<7))
        try userScrolls(opened, toRow: 8, section: 0, at: 0.37)
        try await Task.sleep(for: .milliseconds(500))
        let anchor = try #require(opened.webtoon.anchor)
        let before = try opened.frame(row: 7, section: 0).height
        opened.loader.release()
        try await waitUntil { try opened.frame(row: 7, section: 0).height > before + 100 }
        try #require(try opened.frame(row: 7, section: 0).height > before + 100, "page 7 did not grow")
        #expect(opened.webtoon.anchor == anchor)
        let distance = try opened.distanceFromTheAnchor()
        #expect(abs(distance) < 0.5, "the anchor's point is \(distance) pt from its place")
        #expect(opened.scrollViewsAgree)
        await opened.close()
    }

    /// D6: the anchor taken on a page with its provisional height (30 % into it); the page then gets its real height
    /// (about twice): the line stays at the same distance from the top of the page.
    @Test func theMiddleItemGrowingFromItsProvisionalHeightKeepsItsTop() async throws {
        let opened = try await open(mangaKey: "creceancla", startPage: 8, holding: Self.c2(9..<10))
        let provisional = try opened.frame(row: 10, section: 0)
        try #require(provisional.height < 700, "page 10 is not provisional: \(provisional.height)")
        try userScrolls(opened, toRow: 10, section: 0, at: 0.3)
        try await Task.sleep(for: .milliseconds(500))
        let webtoon = opened.webtoon
        try #require(webtoon.anchor?.measured == false, "the anchor is not on a provisional page")
        let line = webtoon.collectionNode.contentOffset.y + webtoon.collectionNode.bounds.height / 2
        let intoBefore = line - (try opened.frame(row: 10, section: 0).minY)
        opened.loader.release()
        try await waitUntil { try opened.frame(row: 10, section: 0).height > 1000 }
        let real = try opened.frame(row: 10, section: 0)
        try #require(real.height > 1000, "page 10 did not grow: \(real.height)")
        let lineAfter = webtoon.collectionNode.contentOffset.y + webtoon.collectionNode.bounds.height / 2
        #expect(abs((lineAfter - real.minY) - intoBefore) < 1, "into page 10: \(intoBefore) → \(lineAfter - real.minY)")
        #expect(webtoon.anchor?.measured == true)
        #expect(opened.scrollViewsAgree)
        await opened.close()
    }

    /// A chapter put in above (its pages provisional), then its pages coming and shrinking: the anchor and its place
    /// on screen stay.
    @Test func insertingAChapterAboveAndItsPagesComingKeepTheAnchor() async throws {
        let opened = try await open(mangaKey: "insertarancla", startPage: 2, holding: Self.allOfC1)
        try userScrolls(opened, toRow: 0, section: 0, at: 0.6)
        try await Task.sleep(for: .milliseconds(300))
        let anchor = try #require(opened.webtoon.anchor)
        try await putThePreviousChapterIn(opened)
        #expect(opened.webtoon.anchor == anchor)
        var distance = try opened.distanceFromTheAnchor()
        #expect(abs(distance) < 0.5, "after the insert: \(distance) pt")
        #expect(opened.scrollViewsAgree)
        let last = opened.webtoon.collectionNode.numberOfItems(inSection: 0) - 1
        let before = try opened.frame(row: last, section: 0).height
        opened.loader.release()
        try await waitUntil { try opened.frame(row: last, section: 0).height < before - 100 }
        try #require(try opened.frame(row: last, section: 0).height < before - 100, "chapter 1's last page did not shrink")
        #expect(opened.webtoon.anchor == anchor)
        distance = try opened.distanceFromTheAnchor()
        #expect(abs(distance) < 0.5, "after chapter 1's pages came: \(distance) pt")
        #expect(opened.scrollViewsAgree)
        await opened.close()
    }

    /// C4: the transitions reloaded (refreshInfoPages): the anchor and its place stay.
    @Test func reloadingTheTransitionsKeepsTheAnchor() async throws {
        let opened = try await open(mangaKey: "transicionesancla", startPage: 3, holding: { _ in false })
        try userScrolls(opened, toRow: 4, section: 0, at: 0.3)
        try await Task.sleep(for: .milliseconds(500))
        let anchor = try #require(opened.webtoon.anchor)
        opened.webtoon.refreshInfoPages()
        try await Task.sleep(for: .seconds(1))
        #expect(opened.webtoon.anchor == anchor)
        let distance = try opened.distanceFromTheAnchor()
        #expect(abs(distance) < 0.5, "\(distance) pt")
        #expect(opened.scrollViewsAgree)
        await opened.close()
    }

    /// I9: after every kind of relayout (pages above growing, the window's width changing and back), both scroll
    /// views have the same offset.
    @Test func bothScrollViewsHaveTheSameOffsetAfterEveryRelayout() async throws {
        let opened = try await open(mangaKey: "dosscroll", startPage: 8, holding: Self.c2(0..<7))
        try userScrolls(opened, toRow: 9, section: 0, at: 0.5)
        try await Task.sleep(for: .milliseconds(500))
        opened.loader.release()
        try await Task.sleep(for: .seconds(3))
        #expect(opened.scrollViewsAgree, "after the pages above grew")
        opened.window.frame = CGRect(x: 0, y: 0, width: 600, height: 874)
        opened.window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        #expect(opened.scrollViewsAgree, "600 wide")
        opened.window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        opened.window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
        #expect(opened.scrollViewsAgree, "back to 402")
        await opened.close()
    }

    // MARK: - Paso 4

    /// A rotation with its transition (portrait → landscape → portrait): the anchor and its place stay, to half a
    /// point (the H tests allow 2 % of the page).
    @Test func aRotationKeepsTheAnchor() async throws {
        let opened = try await open(mangaKey: "giroancla", startPage: 5, holding: { _ in false })
        try userScrolls(opened, toRow: 6, section: 0, at: 0.35)
        try await Task.sleep(for: .milliseconds(500))
        let anchor = try #require(opened.webtoon.anchor)
        for size in [CGSize(width: 874, height: 402), CGSize(width: 402, height: 874)] {
            let coordinator = SteppedTransitionCoordinator()
            opened.webtoon.viewWillTransition(to: size, with: coordinator)
            opened.window.frame = CGRect(origin: .zero, size: size)
            coordinator.runAnimations()
            opened.window.layoutIfNeeded()
            coordinator.complete()
            try await Task.sleep(for: .seconds(1))
            #expect(opened.webtoon.anchor == anchor, "\(size)")
            let distance = try opened.distanceFromTheAnchor()
            #expect(abs(distance) < 0.5, "\(size): \(distance) pt")
            #expect(opened.scrollViewsAgree, "\(size)")
        }
        await opened.close()
    }

    /// Out of front, the window takes other sizes without a transition (iPadOS: landscape, a shorter one, back):
    /// back in front, the anchor and its place are as they were, and so is the page.
    @Test func aRotationOutOfFrontKeepsTheAnchor() async throws {
        let opened = try await open(mangaKey: "girofuera", startPage: 5, holding: { _ in false })
        try userScrolls(opened, toRow: 6, section: 0, at: 0.35)
        try await Task.sleep(for: .seconds(1))
        let anchor = try #require(opened.webtoon.anchor)
        let page = opened.reader.currentPage
        opened.center.post(name: UIApplication.willResignActiveNotification, object: nil)
        opened.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        for size in [CGSize(width: 874, height: 402), CGSize(width: 402, height: 700), CGSize(width: 402, height: 874)] {
            opened.window.frame = CGRect(origin: .zero, size: size)
            opened.window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
        }
        opened.center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.webtoon.anchor == anchor)
        let distance = try opened.distanceFromTheAnchor()
        #expect(abs(distance) < 0.5, "\(distance) pt")
        #expect(opened.reader.currentPage == page)
        await opened.close()
    }

    // MARK: - Paso 5

    /// Risk 6: in chapter 2 at its top, the user lets go with speed (decelerating) while chapter 1's pages above
    /// come and shrink: the chapter and the anchor stay.
    @Test func aLayoutChangeDuringADecelerationDoesNotChangeTheChapter() async throws {
        let opened = try await open(mangaKey: "inerciacapitulo", startPage: 2, holding: Self.allOfC1)
        try await putThePreviousChapterIn(opened)
        // the middle of the screen near the top of chapter 2's transition: chapter 1's last page is on screen above it
        // (so the reader asks for its image; just above the screen it may not, under the suite's load)
        try userScrolls(opened, toRow: 0, section: 1, at: 0.2)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.chapter.key == "c2")
        let webtoon = opened.webtoon
        let anchor = try #require(webtoon.anchor)
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: true)
        let last = webtoon.collectionNode.numberOfItems(inSection: 0) - 1
        let before = try opened.frame(row: last, section: 0).height
        opened.loader.release()
        try await waitUntil { try opened.frame(row: last, section: 0).height < before - 100 }
        try #require(try opened.frame(row: last, section: 0).height < before - 100, "chapter 1's pages did not shrink")
        webtoon.scrollViewDidEndDecelerating(webtoon.scrollView)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.reader.chapter.key == "c2")
        #expect(webtoon.anchor?.chapterKey == "c2" && webtoon.anchor?.item == anchor.item, "\(String(describing: webtoon.anchor))")
        let distance = try opened.distanceFromTheAnchor()
        #expect(abs(distance) < 0.5, "\(distance) pt")
        await opened.close()
    }

    /// F3/G1 against a real relayout: up into chapter 1's last page from below (entered from below), then, during
    /// a deceleration, chapter 1's pages above come and shrink: the content moves up by more than a screen,
    /// but the user did not go up inside the chapter. Back down into chapter 2: chapter 1 is not completed (it was
    /// only peeked at from below). With the direction taken from the offset (before step 5), the shrinking counted
    /// as going up and reading down completed it.
    @Test func pagesShrinkingAboveDuringADecelerationAreNotGoingUpInsideTheChapter() async throws {
        let opened = try await open(mangaKey: "encogenarriba", startPage: 2, holding: Self.allOfC1)
        try await putThePreviousChapterIn(opened)
        let webtoon = opened.webtoon
        let last = webtoon.collectionNode.numberOfItems(inSection: 0) - 1
        // near the top of the page: once it shrinks, the anchor is still inside it (D6 keeps the distance to its top)
        try userScrolls(opened, toRow: last, section: 0, at: 0.15)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.chapter.key == "c1", "not in chapter 1")
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: true)
        let offset = webtoon.collectionNode.contentOffset.y
        opened.loader.release()
        try await waitUntil { offset - webtoon.collectionNode.contentOffset.y > webtoon.collectionNode.bounds.height + 100 }
        // more than a screen: taken as the user going up, it would make reading down count (G1)
        try #require(offset - webtoon.collectionNode.contentOffset.y > webtoon.collectionNode.bounds.height + 100,
                     "the content did not move up by a screen: \(offset) → \(webtoon.collectionNode.contentOffset.y)")
        webtoon.scrollViewDidEndDecelerating(webtoon.scrollView)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.reader.chapter.key == "c1")
        // back down into chapter 2's first page, 100 points a drag
        let target = try opened.frame(row: 1, section: 1).midY
        var y = webtoon.collectionNode.contentOffset.y + webtoon.collectionNode.bounds.height / 2
        while y < target {
            y = min(y + 100, target)
            webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
            webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: y - webtoon.collectionNode.bounds.height / 2), animated: false)
            webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(3))
        #expect(opened.reader.chapter.key == "c2")
        // only peeked at from below: nothing of chapter 1 is saved, nor completed (SUWA-17 D4, F3)
        let previous = await storedProgress(opened.ids[0])
        #expect(previous.progress == nil, "chapter 1 saved at page \(String(describing: previous.progress)): it was only peeked at from below")
        #expect(previous.completed == false, "chapter 1 completed: it was only peeked at from below")
        await opened.close()
    }

    // MARK: - SUWA-39 A: the screen while a chapter is put in or trimmed

    /// Chapters d1...d5 of a manga, all tall (each one is several screens), opened at `start`.
    private static let chain = ["d1", "d2", "d3", "d4", "d5"]

    /// Nobody is dragging: the flags of the last scroll are cleared (a layout's own scroll sets «scrolling»).
    private func settle(_ opened: Opened) async throws {
        opened.webtoon.scrollViewWillBeginDragging(opened.webtoon.scrollView)
        opened.webtoon.scrollViewDidEndDragging(opened.webtoon.scrollView, willDecelerate: false)
        try await Task.sleep(for: .milliseconds(300))
    }

    /// The next chapter the reader will be asked for: its pages are there when `appendNextChapter`/`prependPreviousChapter` ask.
    private func preload(_ opened: Opened, _ key: String) throws {
        let chapter = try #require(opened.chain.first { $0.key == key })
        opened.webtoon.viewModel.preloadedPages = try Self.pages(
            sourceKey: opened.sourceKey, chapterKey: key, in: opened.directory, count: opened.pageCount, size: opened.pageSize
        )
        opened.webtoon.viewModel.preloadedChapter = chapter
    }

    /// The user drags until the middle of the screen is at `row` of the chapter `key` (already put in), and lets go.
    private func readInto(_ opened: Opened, _ key: String, row: Int) async throws {
        let section = try #require(opened.webtoon.chapters.firstIndex { $0.key == key }, "\(key) is not in the reader")
        try userScrolls(opened, toRow: row, section: section, at: 0.5)
        try await Task.sleep(for: .milliseconds(800))
        try #require(opened.reader.chapter.key == key, "the reader is in \(opened.reader.chapter.key), not in \(key)")
        try await settle(opened)
    }

    /// Reading chapter d3 of [d1, d2, d3] (the ones above and the one being read are taller than the screen),
    /// d4 is next: appending it takes the window over its limit and trims d1.
    private func readingTheThirdOfThree(_ mangaKey: String, preloadingTheNext: Bool = true) async throws -> Opened {
        let opened = try await open(mangaKey: mangaKey, startPage: 6, holding: { _ in false }, chain: Self.chain, startKey: "d1")
        for key in ["d2", "d3"] {
            try await settle(opened)
            try preload(opened, key)
            await opened.webtoon.appendNextChapter()
            try await readInto(opened, key, row: 3)
        }
        try #require(opened.webtoon.chapters.map(\.key) == ["d1", "d2", "d3"], "\(opened.webtoon.chapters.map(\.key))")
        if preloadingTheNext {
            try preload(opened, "d4")
        }
        return opened
    }

    /// Reading chapter d2 of [d2, d3, d4] (d1 is next up): putting d1 in above takes the window over its limit and trims d4.
    private func readingTheFirstOfThree(_ mangaKey: String) async throws -> Opened {
        let opened = try await open(mangaKey: mangaKey, startPage: 6, holding: { _ in false }, chain: Self.chain, startKey: "d4")
        for key in ["d3", "d2"] {
            try await settle(opened)
            try preload(opened, key)
            await opened.webtoon.prependPreviousChapter()
            try await readInto(opened, key, row: 8)
        }
        try #require(opened.webtoon.chapters.map(\.key) == ["d2", "d3", "d4"], "\(opened.webtoon.chapters.map(\.key))")
        try preload(opened, "d1")
        return opened
    }

    /// The user drags a little, in the middle of a change of sections.
    private func userDrags(_ opened: Opened) {
        let webtoon = opened.webtoon
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: webtoon.scrollView.contentOffset.y + 30), animated: false)
    }

    /// A page of a chapter above the screen changes its height (another ratio), in the middle of a change of sections.
    /// False if there was no such page.
    private func aPageAboveChangesItsHeight(_ opened: Opened) -> Bool {
        let webtoon = opened.webtoon
        guard
            let node = webtoon.collectionNode.nodeForItem(at: IndexPath(item: 2, section: 1)) as? ReaderWebtoonPageNode,
            case let before = webtoon.collectionNode.view.contentSize.height
        else { return false }
        node.ratio = (node.ratio ?? 1.5) * 0.4
        webtoon.collectionNode.collectionViewLayout.invalidateLayout()
        webtoon.collectionNode.view.layoutIfNeeded()
        return webtoon.collectionNode.view.contentSize.height < before - 100
    }

    /// After the change: the reader still reads what it read, and the screen is where it was.
    private func expectStill(_ opened: Opened, readingKey: String, readingItem: Int, sections: [String], _ what: String) throws {
        let webtoon = opened.webtoon
        #expect(webtoon.anchor?.item == readingItem, "\(what): the anchor is at item \(String(describing: webtoon.anchor?.item)), not \(readingItem)")
        #expect(webtoon.chapters.map(\.key) == sections, "\(what): the chapters are \(webtoon.chapters.map(\.key))")
        #expect(opened.sections == sections.count, "\(what): the collection has \(opened.sections) sections")
        #expect(opened.reader.chapter.key == readingKey, "\(what): the chapter is \(opened.reader.chapter.key)")
        #expect(webtoon.anchor?.chapterKey == readingKey, "\(what): the anchor is \(String(describing: webtoon.anchor))")
        if let distance = try? opened.distanceFromTheAnchor() {
            #expect(abs(distance) <= 1, "\(what): the anchor's point is \(distance) pt from its place")
        } else {
            Issue.record("\(what): no anchor to measure from")
        }
        #expect(opened.scrollViewsAgree, "\(what): the two scroll views have other offsets")
    }

    /// A·1 (i): the user drags while the first chapter is trimmed (the arrays have 3 chapters, the collection 4): the
    /// anchor, the chapter and the screen stay where they were.
    @Test func aDragWhileTheFirstChapterIsTrimmedKeepsTheAnchorAndTheChapter() async throws {
        let opened = try await readingTheThirdOfThree("recortearrastre")
        let webtoon = opened.webtoon
        let item = try #require(webtoon.anchor?.item)
        webtoon.onSectionsMutated = { self.userDrags(opened) }
        await webtoon.appendNextChapter()
        webtoon.onSectionsMutated = nil
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
        try await Task.sleep(for: .seconds(1))
        try expectStill(opened, readingKey: "d3", readingItem: item, sections: ["d2", "d3", "d4"], "drag")
        await opened.close()
    }

    /// A·1 (ii): a page above the screen changes its height in the same moment.
    @Test func aPageAboveChangingItsHeightWhileTheFirstChapterIsTrimmedKeepsTheAnchor() async throws {
        let opened = try await readingTheThirdOfThree("recortealto")
        let webtoon = opened.webtoon
        let item = try #require(webtoon.anchor?.item)
        var changes = 0
        webtoon.onSectionsMutated = {
            if self.aPageAboveChangesItsHeight(opened) {
                changes += 1
            }
        }
        await webtoon.appendNextChapter()
        webtoon.onSectionsMutated = nil
        try await Task.sleep(for: .seconds(1))
        #expect(changes > 0, "no page above changed its height")
        try expectStill(opened, readingKey: "d3", readingItem: item, sections: ["d2", "d3", "d4"], "height")
        await opened.close()
    }

    /// A·1 (iii): the same putting a chapter in above and trimming the last one.
    @Test func aDragWhileTheLastChapterIsTrimmedKeepsTheAnchorAndTheChapter() async throws {
        let opened = try await readingTheFirstOfThree("recortarprepend")
        let webtoon = opened.webtoon
        let item = try #require(webtoon.anchor?.item)
        webtoon.onSectionsMutated = { self.userDrags(opened) }
        await webtoon.prependPreviousChapter()
        webtoon.onSectionsMutated = nil
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
        try await Task.sleep(for: .seconds(1))
        try expectStill(opened, readingKey: "d2", readingItem: item, sections: ["d1", "d2", "d3"], "prepend drag")
        await opened.close()
    }

    /// A·3: the user touches the content right before the trim: it is not done (the screen would move under their
    /// finger); when they let go, the next end of a scroll trims it.
    @Test func theTrimWaitsWhileTheUserIsTouchingAndIsDoneAfterwards() async throws {
        let opened = try await readingTheThirdOfThree("recortetocando")
        let webtoon = opened.webtoon
        let item = try #require(webtoon.anchor?.item)
        var touching = false
        webtoon.isUserTouchingOverride = { touching }
        // the user puts a finger down once the new chapter is in
        webtoon.onSectionsMutated = { touching = true }
        await webtoon.appendNextChapter()
        webtoon.onSectionsMutated = nil
        try await Task.sleep(for: .milliseconds(500))
        try expectStill(opened, readingKey: "d3", readingItem: item, sections: ["d1", "d2", "d3", "d4"], "touching")
        // lets go: the end of the scroll takes the trim that was left
        touching = false
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
        try await waitUntil { webtoon.chapters.count == 3 }
        try expectStill(opened, readingKey: "d3", readingItem: item, sections: ["d2", "d3", "d4"], "after letting go")
        await opened.close()
    }

    // MARK: - SUWA-39 ronda 2

    /// A gate the test opens (a held `pagesLoadGate`).
    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            let continuations = waiting
            waiting = []
            for continuation in continuations {
                continuation.resume()
            }
        }
    }

    /// Whether the chapter is completed in the history, waiting up to `seconds` for it to be saved.
    private func completedInHistory(_ id: ChapterIdentifier, seconds: Double = 5) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .milliseconds(Int(seconds * 1000)) {
            if await storedProgress(id).completed { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// The lines of the journal for the chapter that start with `prefix` (the reader's own notes).
    private func journalLines(_ id: ChapterIdentifier, startingWith prefix: String) -> [String] {
        CompletionJournal.lines().compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5, fields[1] == id.sourceKey, fields[2] == id.mangaKey, fields[3] == id.chapterKey, fields[4].hasPrefix(prefix) else {
                return nil
            }
            return fields[4]
        }
    }

    /// The user reads down: a drag at a time, each one to the page `rows` says (in order), in `section`.
    private func readsDown(_ opened: Opened, rows: [Int], section: Int = 0) async throws {
        for row in rows {
            try userScrolls(opened, toRow: row, section: section, at: 0.5)
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    /// R2-I1: pages of about 150 pt on an iPad's screen (1024 high): opened at page 1, the page the first drag tells is
    /// the one in the middle of the screen, about the fifth. That is not a jump: the screen it opened at showed them.
    /// Reading down with real drags to the final transition completes the chapter.
    @Test(.timeLimit(.minutes(2))) func goingDownShortPagesOnAnIPadScreenCompletesTheChapter() async throws {
        let opened = try await open(
            mangaKey: "paginascortas", startPage: 1, holding: { _ in false }, chain: ["e1"], startKey: "e1",
            windowSize: CGSize(width: 768, height: 1024), pageCount: 30, pageSize: { _, _ in CGSize(width: 768, height: 150) }
        )
        let chapterId = opened.ids[0]
        // short pages: seven of them, about, fit in the screen it opened at
        let seventh = try opened.frame(row: 7, section: 0)
        let screenHeight = opened.webtoon.collectionNode.bounds.height
        try #require(
            seventh.height < 200 && seventh.minY - opened.webtoon.collectionNode.contentOffset.y < screenHeight,
            "the pages are not short: \(seventh), the screen is \(screenHeight) high"
        )
        try await readsDown(opened, rows: Array(5...30))
        try await readsDown(opened, rows: [31])
        let completed = await completedInHistory(chapterId)
        let refusals = journalLines(chapterId, startingWith: "webtoon: no completa")
        #expect(completed, "not completed; the journal says \(refusals); at page \(opened.reader.currentPage)")
        #expect(refusals.isEmpty, "\(refusals)")
        await opened.close()
    }

    /// R2-I2: `setChapter` puts the new chapter in `chapters` at once and the old pages stay until the new ones come
    /// (seconds, with a WebView). A drag in that time must not anchor the new chapter on the old chapter's pages: no
    /// anchor, no page reported for the new chapter, and its descent goes on when the pages come.
    @Test(.timeLimit(.minutes(2))) func aDragWhileTheNewChapterLoadsDoesNotAnchorItOnTheOldPages() async throws {
        let opened = try await open(mangaKey: "cargandoarrastre", startPage: 6, holding: { _ in false }, chain: ["d1", "d2"], startKey: "d1")
        let webtoon = opened.webtoon
        try await settle(opened)
        try preload(opened, "d2")
        let gate = Gate()
        webtoon.pagesLoadGate = { await gate.wait() }
        let next = try #require(opened.chain.first { $0.key == "d2" })
        opened.reader.setChapter(next)
        opened.reader.loadCurrentChapter()
        try await Task.sleep(for: .milliseconds(500))
        try #require(webtoon.chapters.map(\.key) == ["d2"], "\(webtoon.chapters.map(\.key))")
        try #require(opened.sections == 1, "the collection has \(opened.sections) sections")
        // the user drags on the old pages
        try userScrolls(opened, toRow: 8, section: 0, at: 0.5)
        try await Task.sleep(for: .milliseconds(500))
        #expect(webtoon.anchor == nil, "anchored on the old pages: \(String(describing: webtoon.anchor))")
        #expect(opened.reader.currentPage < 1, "the new chapter was told at page \(opened.reader.currentPage)")
        await gate.open()
        webtoon.pagesLoadGate = nil
        try await waitUntil { webtoon.anchor?.chapterKey == "d2" }
        try #require(webtoon.anchor?.chapterKey == "d2", "d2 did not open: \(String(describing: webtoon.anchor))")
        // its descent goes on: reading it down to the end completes it
        try await readsDown(opened, rows: Array(2...12))
        try await readsDown(opened, rows: [13])
        let completed = await completedInHistory(opened.ids[1])
        #expect(completed, "d2 not completed: \(journalLines(opened.ids[1], startingWith: "webtoon:"))")
        await opened.close()
    }






}
}
