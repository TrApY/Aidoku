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
    /// chapter 1's are short (300×200: ~268 pt), so they shrink when they come.
    private static func pages(sourceKey: String, chapterKey: String, in directory: URL) throws -> [Aidoku.Page] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<pageCount {
            let size = CGSize(width: 300, height: chapterKey == "c1" ? 200 : (index % 2 == 0 ? 900 : 860))
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
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
            let section = sections == 2 && anchor.chapterKey == "c2" ? 1 : 0
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
    private func open(mangaKey: String, startPage: Int, holding: @escaping @Sendable (String) -> Bool) async throws -> Opened {
        let previous = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let chapter = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)
        let manga = AidokuRunner.Manga(sourceKey: "lectoranclalayout", key: mangaKey, title: "Webtoon", chapters: [chapter, previous])
        let ids = [previous, chapter].map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key) }
        for id in ids {
            await removeTestHistory(id)
        }
        await DataRepositories.shared.history.savePage(PageSave(chapter: ids[1], page: startPage, totalPages: Self.pageCount))
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anclalayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key, in: directory)
        let previousPages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: previous.key, in: directory)

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
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
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
            pipeline: pipeline, loader: loader
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
        try await Task.sleep(for: .seconds(3))
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
        try await Task.sleep(for: .seconds(3))
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
        try await Task.sleep(for: .seconds(3))
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
        try await Task.sleep(for: .seconds(3))
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

    /// Risk 6: in chapter 2 near its top, the user lets go with speed (decelerating) while chapter 1's pages above
    /// come and shrink: the chapter and the anchor stay.
    @Test func aLayoutChangeDuringADecelerationDoesNotChangeTheChapter() async throws {
        let opened = try await open(mangaKey: "inerciacapitulo", startPage: 2, holding: Self.allOfC1)
        try await putThePreviousChapterIn(opened)
        try userScrolls(opened, toRow: 1, section: 1, at: 0.2)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.chapter.key == "c2")
        let webtoon = opened.webtoon
        let anchor = try #require(webtoon.anchor)
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: true)
        let last = webtoon.collectionNode.numberOfItems(inSection: 0) - 1
        let before = try opened.frame(row: last, section: 0).height
        opened.loader.release()
        try await Task.sleep(for: .seconds(2))
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
    /// a deceleration, chapter 1's pages above come and shrink: the content moves up by more than half a screen,
    /// but the user did not go up inside the chapter. Back down into chapter 2: chapter 1 is not completed (it was
    /// only peeked at from below). With the direction taken from the offset (before step 5), the shrinking counted
    /// as going up and reading down completed it.
    @Test func pagesShrinkingAboveDuringADecelerationAreNotGoingUpInsideTheChapter() async throws {
        let opened = try await open(mangaKey: "encogenarriba", startPage: 2, holding: Self.allOfC1)
        try await putThePreviousChapterIn(opened)
        let webtoon = opened.webtoon
        let last = webtoon.collectionNode.numberOfItems(inSection: 0) - 1
        try userScrolls(opened, toRow: last, section: 0, at: 0.5)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.chapter.key == "c1", "not in chapter 1")
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: true)
        let offset = webtoon.collectionNode.contentOffset.y
        opened.loader.release()
        try await Task.sleep(for: .seconds(2))
        try #require(offset - webtoon.collectionNode.contentOffset.y > webtoon.collectionNode.bounds.height / 2,
                     "the content did not move up by half a screen: \(offset) → \(webtoon.collectionNode.contentOffset.y)")
        webtoon.scrollViewDidEndDecelerating(webtoon.scrollView)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.reader.chapter.key == "c1")
        // back down into chapter 2's first page, 300 points a drag
        let target = try opened.frame(row: 1, section: 1).midY
        var y = webtoon.collectionNode.contentOffset.y + webtoon.collectionNode.bounds.height / 2
        while y < target {
            y = min(y + 300, target)
            webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
            webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: y - webtoon.collectionNode.bounds.height / 2), animated: false)
            webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(3))
        #expect(opened.reader.chapter.key == "c2")
        #expect(await storedProgress(opened.ids[0]).completed == false, "chapter 1 completed: it was only peeked at from below")
        await opened.close()
    }

}
}
