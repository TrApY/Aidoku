//
//  ReaderWebtoonScrollUpTests.swift
//  AidokuTests
//
//  SUWA-17 A: reading the middle of chapter N in the webtoon reader and scrolling up, page by page. The pages
//  above still have their provisional height and grow as their images load; near the start the previous chapter
//  is put in above. None of that is the user moving: the page on screen must stay the one the user scrolled to,
//  and the reader must stay in N until the user goes up past N's first page. Through the real ReaderViewController
//  and webtoon reader, with real images taller than the provisional height.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Testing
import UIKit

@testable import Aidoku

extension ImagePipelineSwappingTests {
@MainActor
@Suite(.serialized) struct ReaderWebtoonScrollUpTests {
    private static let pageCount = 12

    private static func pages(sourceKey: String, chapterKey: String, in directory: URL) throws -> [Aidoku.Page] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<pageCount {
            let size = CGSize(width: 300, height: index % 2 == 0 ? 900 : 860)
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let url = directory.appendingPathComponent("\(chapterKey)-\(index).png")
            try data.write(to: url)
            pages.append(Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, imageURL: url.absoluteString))
        }
        return pages
    }

    @MainActor
    private struct Opened {
        let reader: ReaderViewController
        let webtoon: ReaderWebtoonViewController
        let chapterId: ChapterIdentifier
        let window: UIWindow
        let directory: URL
        let modeKey: String
        /// Where the reader hears the app going out of front and back (SUWA-17 H).
        let center: NotificationCenter

        func close() async {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
            await removeTestHistory(chapterId)
        }

        var shownPage: Int { webtoon.getCurrentPage() }
        var chapterKey: String { reader.chapter.key }
        /// The section and row in the middle of the screen.
        var middle: IndexPath? { webtoon.getCurrentPagePath() }
        /// The section of the last chapter (N): the previous one, once put in, is above it.
        var lastSection: Int { webtoon.collectionNode.numberOfSections - 1 }
    }

    /// Opens chapter N ("c2", with "c1" before it) at `startPage`, with the previous chapter's pages ready.
    private func open(mangaKey: String, startPage: Int) async throws -> Opened {
        let previous = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let chapter = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)
        let manga = AidokuRunner.Manga(sourceKey: "lectorsubir", key: mangaKey, title: "Webtoon", chapters: [chapter, previous])
        let chapterId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        await removeTestHistory(chapterId)
        await DataRepositories.shared.history.savePage(PageSave(chapter: chapterId, page: startPage, totalPages: Self.pageCount))
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key, in: directory)
        let previousPages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: previous.key, in: directory)

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
        try await Task.sleep(for: .seconds(4))
        // what the reader gets when it asks for the previous chapter
        webtoon.viewModel.preloadedChapter = previous
        webtoon.viewModel.preloadedPages = previousPages
        return Opened(
            reader: reader, webtoon: webtoon, chapterId: chapterId, window: window, directory: directory, modeKey: modeKey, center: center
        )
    }

    /// The user drags until the middle of the screen is in `row` of `section`, and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int, section: Int) throws {
        let webtoon = opened.webtoon
        let frame = try #require(
            webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: section))?.frame
        )
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        let y = frame.midY - webtoon.collectionNode.bounds.height / 2
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
    }

    /// Waits until the previous chapter is in and its images have loaded, then a little more for the layout to
    /// settle. The reader puts it in only once the scroll has stopped, and any offset change (an image loading
    /// below) counts as scrolling again until the next time the user lets go: if it is not in after 4 s, the
    /// user touches the screen and lets go without moving, as one does.
    private func waitForThePreviousChapter(_ opened: Opened) async throws {
        try await Task.sleep(for: .seconds(4))
        if opened.lastSection != 1 {
            opened.webtoon.scrollViewWillBeginDragging(opened.webtoon.scrollView)
            opened.webtoon.scrollViewDidEndDragging(opened.webtoon.scrollView, willDecelerate: false)
        }
        for _ in 0..<24 where opened.lastSection != 1 {
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(2))
    }

    @Test func scrollingUpInsideTheChapterStaysInItAndOnThePage() async throws {
        let opened = try await open(mangaKey: "subir", startPage: 8)
        #expect(opened.chapterKey == "c2")
        // down to page 2: from page 1 the top of the screen may already be at the start, which puts the previous
        // chapter in (checked below, once it is done)
        for page in stride(from: 7, through: 2, by: -1) {
            try userScrolls(opened, toRow: page, section: opened.lastSection)
            // the images above load and grow; near the start the previous chapter goes in above
            try await Task.sleep(for: .seconds(2))
            #expect(opened.chapterKey == "c2", "after scrolling up to page \(page)")
            #expect(opened.shownPage == page, "after scrolling up to page \(page)")
            #expect(opened.middle == IndexPath(row: page, section: opened.lastSection), "after scrolling up to page \(page)")
        }
        // up to the start of the chapter (its transition, above page 1): the previous chapter goes in above, its
        // images load and grow, and the user is still at the start of N
        try userScrolls(opened, toRow: 0, section: opened.lastSection)
        try await waitForThePreviousChapter(opened)
        #expect(opened.lastSection == 1, "the previous chapter was not put in")
        #expect(opened.chapterKey == "c2")
        #expect(opened.middle == IndexPath(row: 0, section: opened.lastSection))
        #expect(opened.reader.currentPage == 1)
        await opened.close()
    }

    @Test func goingUpPastTheFirstPageChangesToThePreviousChapter() async throws {
        let opened = try await open(mangaKey: "subirycambiar", startPage: 2)
        try userScrolls(opened, toRow: 0, section: opened.lastSection)
        try await waitForThePreviousChapter(opened)
        #expect(opened.chapterKey == "c2")
        try #require(opened.lastSection == 1, "the previous chapter was not put in")
        // the user goes on up, into the previous chapter's last page
        let previousLast = opened.webtoon.collectionNode.numberOfItems(inSection: 0) - 1
        try userScrolls(opened, toRow: previousLast, section: 0)
        try await Task.sleep(for: .seconds(2))
        #expect(opened.chapterKey == "c1")
        await opened.close()
    }
}
}

// MARK: - SUWA-17 F3: a chapter of one tall page entered from below
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// Chapter N ("c2") open, with chapter N-1 ("c1") a single page much taller than the screen.
    private func openWithATallPreviousChapter(mangaKey: String) async throws -> Opened {
        let opened = try await open(mangaKey: mangaKey, startPage: 3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 300, height: 3000)
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            for band in 0..<30 {
                UIColor(hue: CGFloat(band) / 30, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: CGFloat(band) * 100, width: 300, height: 100))
            }
        }
        let url = opened.directory.appendingPathComponent("c1-alta.png")
        try data.write(to: url)
        opened.webtoon.viewModel.preloadedPages = [Aidoku.Page(sourceId: "lectorsubir", chapterId: "c1", index: 0, imageURL: url.absoluteString)]
        // up to the start of chapter N (its transition, above page 1): chapter N-1 goes in above
        try userScrolls(opened, toRow: 0, section: opened.lastSection)
        try await waitForThePreviousChapter(opened)
        try #require(opened.lastSection == 1, "chapter 1 did not go in above")
        return opened
    }

    /// The user drags until the middle of the screen is at `y` of the content, and lets go.
    private func drag(_ opened: Opened, middleAt y: CGFloat) {
        let webtoon = opened.webtoon
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: y - webtoon.collectionNode.bounds.height / 2), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
    }

    private func pageFrame(_ opened: Opened) throws -> CGRect {
        try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 1, section: 0))?.frame)
    }

    /// Up into the end of the tall page from below, further up inside it, and read down to its end and on into
    /// chapter N: chapter N-1 is completed (it was read going down).
    @Test func aOnePageChapterEnteredFromBelowAndReadDownIsCompleted() async throws {
        let opened = try await openWithATallPreviousChapter(mangaKey: "unapagina")
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        await removeTestHistory(previousId)
        var frame = try pageFrame(opened)
        try #require(frame.height > 2 * opened.webtoon.collectionNode.bounds.height, "the page is \(frame.height) high")
        drag(opened, middleAt: frame.maxY - 150)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.chapterKey == "c1", "not in chapter 1")
        // further up inside it, then down through it
        frame = try pageFrame(opened)
        var y = frame.maxY - 150 - opened.webtoon.collectionNode.bounds.height
        drag(opened, middleAt: y)
        try await Task.sleep(for: .milliseconds(500))
        let firstOfN = try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 1, section: 1))?.frame)
        while y < firstOfN.midY {
            y = min(y + 300, firstOfN.midY)
            drag(opened, middleAt: y)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(2))
        #expect(opened.chapterKey == "c2")
        #expect(await storedProgress(previousId).completed == true, "chapter 1 read down to its end")
        await removeTestHistory(previousId)
        await opened.close()
    }

    /// Up into the end of the tall page from below and straight back down: not completed (SUWA-17 D5).
    @Test func aOnePageChapterOnlyPeekedAtFromBelowIsNotCompleted() async throws {
        let opened = try await openWithATallPreviousChapter(mangaKey: "unapaginaasomar")
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        await removeTestHistory(previousId)
        let frame = try pageFrame(opened)
        drag(opened, middleAt: frame.maxY - 150)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.chapterKey == "c1", "not in chapter 1")
        let firstOfN = try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 1, section: 1))?.frame)
        var y = frame.maxY - 150
        while y < firstOfN.midY {
            y = min(y + 300, firstOfN.midY)
            drag(opened, middleAt: y)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(2))
        #expect(opened.chapterKey == "c2")
        #expect(await storedProgress(previousId).completed == false, "chapter 1 only peeked at")
        await removeTestHistory(previousId)
        await opened.close()
    }
}

// MARK: - SUWA-17 G1: going up into the previous chapter and back down does not read it
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// Chapter N ("c2") open, with chapter N-1 ("c1") of `smallPages` pages and a last one much taller than the
    /// screen, gone in above.
    private func openWithATallLastPage(mangaKey: String, smallPages: Int) async throws -> Opened {
        let opened = try await open(mangaKey: mangaKey, startPage: 3)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0...smallPages {
            let tall = index == smallPages
            let size = CGSize(width: 300, height: tall ? 3000 : 500)
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                for band in 0..<Int(size.height / 100) {
                    UIColor(hue: CGFloat(band % 30) / 30, saturation: 0.6, brightness: tall ? 0.9 : 0.6, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: CGFloat(band) * 100, width: 300, height: 100))
                }
            }
            let url = opened.directory.appendingPathComponent("c1-\(index).png")
            try data.write(to: url)
            pages.append(Aidoku.Page(sourceId: "lectorsubir", chapterId: "c1", index: index, imageURL: url.absoluteString))
        }
        opened.webtoon.viewModel.preloadedPages = pages
        try userScrolls(opened, toRow: 0, section: opened.lastSection)
        try await waitForThePreviousChapter(opened)
        try #require(opened.lastSection == 1, "chapter 1 did not go in above")
        return opened
    }

    private func frame(_ opened: Opened, row: Int, section: Int) throws -> CGRect {
        try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: section))?.frame)
    }

    /// The user goes down from `y` (middle of the screen) to the middle of chapter N's first page, 300 points a drag.
    private func dragDown(_ opened: Opened, from y: CGFloat) async throws {
        let firstOfN = try frame(opened, row: 1, section: 1)
        var y = y
        while y < firstOfN.midY {
            y = min(y + 300, firstOfN.midY)
            drag(opened, middleAt: y)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(3))
    }

    /// Up from N into the end of N-1's tall last page, half a screen and a bit further up inside it, and back down
    /// to N: N-1 is not completed and nothing of it is saved (JoTa, 17-nov).
    @Test func goingUpInsideATallLastPageAndBackDownDoesNotComplete() async throws {
        let opened = try await openWithATallPreviousChapter(mangaKey: "asomaralto")
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        await removeTestHistory(previousId)
        let page = try frame(opened, row: 1, section: 0)
        drag(opened, middleAt: page.maxY - 150)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.chapterKey == "c1", "not in chapter 1")
        let up = page.maxY - 150 - opened.webtoon.collectionNode.bounds.height * 0.6
        drag(opened, middleAt: up)
        try await Task.sleep(for: .milliseconds(500))
        try await dragDown(opened, from: up)
        #expect(opened.chapterKey == "c2")
        let stored = await storedProgress(previousId)
        #expect(stored.completed == false, "chapter 1 completed going up and back down")
        #expect(stored.progress == nil, "chapter 1 saved at \(String(describing: stored.progress))")
        await removeTestHistory(previousId)
        await opened.close()
    }

    /// The same with N-1 completed and being read again (at its page 2): its page stays.
    @Test func goingUpInsideTheLastPageOfAChapterReadAgainKeepsItsPage() async throws {
        let opened = try await openWithATallLastPage(mangaKey: "asomarreleido", smallPages: 3)
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        await removeTestHistory(previousId)
        await DataRepositories.shared.history.savePage(PageSave(chapter: previousId, page: 4, totalPages: 4, scrollPosition: nil))
        await DataRepositories.shared.history.markCompleted([previousId], date: Date())
        await DataRepositories.shared.history.savePage(PageSave(chapter: previousId, page: 2, totalPages: 4, scrollPosition: nil))
        let seeded = await storedProgress(previousId)
        try #require(seeded.completed && seeded.progress == 2, "seeded \(seeded)")
        let last = try frame(opened, row: 4, section: 0)
        drag(opened, middleAt: last.maxY - 150)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.chapterKey == "c1", "not in chapter 1")
        let up = last.maxY - 150 - opened.webtoon.collectionNode.bounds.height * 0.6
        drag(opened, middleAt: up)
        try await Task.sleep(for: .milliseconds(500))
        try await dragDown(opened, from: up)
        #expect(opened.chapterKey == "c2")
        let stored = await storedProgress(previousId)
        #expect(stored.progress == 2, "chapter 1's page while reading it again: \(String(describing: stored.progress))")
        #expect(stored.completed == true)
        await removeTestHistory(previousId)
        await opened.close()
    }

    /// Up from N into N-1, further up to its page 2 and read down from there to N: N-1 is completed.
    @Test func readingThePreviousChapterDownFromAnEarlierPageCompletesIt() async throws {
        let opened = try await openWithATallLastPage(mangaKey: "leerbajando", smallPages: 3)
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        await removeTestHistory(previousId)
        let last = try frame(opened, row: 4, section: 0)
        drag(opened, middleAt: last.maxY - 150)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.chapterKey == "c1", "not in chapter 1")
        let second = try frame(opened, row: 2, section: 0)
        drag(opened, middleAt: second.midY)
        try await Task.sleep(for: .seconds(1))
        try await dragDown(opened, from: second.midY)
        #expect(opened.chapterKey == "c2")
        #expect(await storedProgress(previousId).completed == true, "chapter 1 read down from its page 2")
        await removeTestHistory(previousId)
        await opened.close()
    }
}

// MARK: - SUWA-17 G2: only the user's own scrolling counts as going up
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// Entered from below into a one-page chapter; the layout moves the content up two screens (a page above
    /// shrinking as it's measured), and the user goes down to N: not completed.
    @Test func aLayoutAdjustmentUpIsNotTheUserGoingUp() async throws {
        let opened = try await openWithATallPreviousChapter(mangaKey: "reajuste")
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        await removeTestHistory(previousId)
        let page = try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 1, section: 0))?.frame)
        let height = opened.webtoon.collectionNode.bounds.height
        drag(opened, middleAt: page.maxY - 150)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.chapterKey == "c1", "not in chapter 1")
        // not the user: no drag
        let moved = page.maxY - 150 - 2 * height
        opened.webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: moved - height / 2), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        // SUWA-19: the move is not the user's, so the screen is back on the anchor (it neither stays two screens up
        // nor counts as going up); the user then goes down from where the screen is
        let middle = opened.webtoon.collectionNode.contentOffset.y + height / 2
        let anchor = try #require(opened.webtoon.anchor, "no anchor")
        let anchored = try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: anchor.item, section: 0))?.frame)
        let expected = anchored.minY + anchored.height * anchor.fraction
        #expect(abs(middle - expected) < 1, "the screen is not back on the anchor: \(middle) for \(expected)")
        let firstOfN = try #require(opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 1, section: 1))?.frame)
        var y = middle
        while y < firstOfN.midY {
            y = min(y + 300, firstOfN.midY)
            drag(opened, middleAt: y)
            try await Task.sleep(for: .milliseconds(150))
        }
        try await Task.sleep(for: .seconds(3))
        #expect(opened.chapterKey == "c2")
        #expect(await storedProgress(previousId).completed == false, "completed by a layout adjustment")
        await removeTestHistory(previousId)
        await opened.close()
    }
}

// MARK: - SUWA-17 H: the window's size changing (iPadOS: app switcher, Stage Manager, windows) does not change the chapter
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// The window takes `width`×`height`, as iPadOS does with the app's window (no viewWillTransition).
    private func resize(_ opened: Opened, width: CGFloat, height: CGFloat) async throws {
        opened.window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        opened.window.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))
    }

    /// The cell in the middle of the screen and how far into it the middle is (0 its top, 1 its bottom).
    private func middleOfScreen(_ opened: Opened) throws -> (path: IndexPath, fraction: CGFloat) {
        let webtoon = opened.webtoon
        let path = try #require(webtoon.getCurrentPagePath(), "nothing in the middle of the screen")
        let frame = try #require(webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: path)?.frame)
        let middle = webtoon.collectionNode.contentOffset.y + webtoon.collectionNode.bounds.height / 2
        return (path, (middle - frame.minY) / frame.height)
    }

    /// Chapter N ("c2") at `page`, with N-1 ("c1") put in above it, in a window of `width`×`height`.
    private func openInTheSecondChapter(mangaKey: String, page: Int, width: CGFloat, height: CGFloat) async throws -> Opened {
        let opened = try await open(mangaKey: mangaKey, startPage: 2)
        try await resize(opened, width: width, height: height)
        try userScrolls(opened, toRow: 0, section: opened.lastSection)
        try await waitForThePreviousChapter(opened)
        try #require(opened.lastSection == 1, "chapter 1 did not go in above")
        try userScrolls(opened, toRow: page, section: 1)
        try await Task.sleep(for: .seconds(3))
        try #require(opened.chapterKey == "c2" && opened.reader.currentPage == page,
                     "not at chapter 2's page \(page): \(opened.chapterKey) \(opened.reader.currentPage)")
        return opened
    }

    /// Out of front, iPadOS lays the app out again at other sizes (the app switcher's snapshots, Stage Manager):
    /// 820×1180 → 1180×820 → 820×1180 with the app inactive. Back in front: the same chapter, page and place.
    @Test func aSizeChangeWhileInactiveKeepsTheChapterAndThePage() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "tamano", page: 3, width: 820, height: 1180)
        let before = try middleOfScreen(opened)
        opened.center.post(name: UIApplication.willResignActiveNotification, object: nil)
        opened.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await resize(opened, width: 1180, height: 820)
        #expect(opened.chapterKey == "c2", "in landscape, out of front")
        try await resize(opened, width: 820, height: 1180)
        opened.center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .seconds(2))
        #expect(opened.chapterKey == "c2")
        #expect(opened.reader.currentPage == 3)
        let after = try middleOfScreen(opened)
        #expect(after.path == before.path, "middle of the screen \(before) → \(after)")
        #expect(abs(after.fraction - before.fraction) < 0.05, "middle of the screen \(before) → \(after)")
        await opened.close()
    }

    /// Nothing in the middle of the screen (past the end of the content, as when it gets shorter) while in the
    /// second section: the reader stays in its chapter, not in the first section's.
    @Test func nothingInTheMiddleOfTheScreenDoesNotChangeTheChapter() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "sinpagina", page: 3, width: 402, height: 874)
        let webtoon = opened.webtoon
        let end = webtoon.collectionNode.collectionViewLayout.collectionViewContentSize.height
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: end - webtoon.collectionNode.bounds.height / 2 + 40), animated: false)
        let path = webtoon.getCurrentPagePath()
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
        try #require(path == nil, "a page in the middle: \(String(describing: path))")
        try await Task.sleep(for: .seconds(1))
        #expect(opened.chapterKey == "c2")
        await opened.close()
    }

    /// With the app inactive, the content moving into the previous chapter does not change the chapter, and
    /// nothing is saved.
    @Test func withTheAppInactiveMovingIntoAnotherChapterDoesNotChangeIt() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "inactivaotro", page: 3, width: 402, height: 874)
        let previousId = ChapterIdentifier(sourceKey: opened.chapterId.sourceKey, mangaKey: opened.chapterId.mangaKey, chapterKey: "c1")
        let saved = await storedProgress(opened.chapterId)
        opened.center.post(name: UIApplication.willResignActiveNotification, object: nil)
        let page = try frame(opened, row: 5, section: 0)
        drag(opened, middleAt: page.midY)
        try await Task.sleep(for: .seconds(3))
        #expect(opened.chapterKey == "c2")
        #expect(await storedProgress(opened.chapterId).progress == saved.progress, "chapter 2 saved again")
        #expect(await storedProgress(previousId).progress == nil, "chapter 1 saved")
        opened.center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await opened.close()
    }

    /// The window 400 → 600 → 400 wide with the app in front and nobody scrolling (Stage Manager, a window
    /// resized): the page in the middle of the screen stays there, at the same place inside it.
    @Test func aWidthChangeKeepsTheMiddlePage() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "anchuracentro", page: 3, width: 400, height: 874)
        let before = try middleOfScreen(opened)
        try await resize(opened, width: 600, height: 874)
        let wide = try middleOfScreen(opened)
        #expect(wide.path == before.path, "600 wide: \(before) → \(wide)")
        #expect(abs(wide.fraction - before.fraction) < 0.02, "600 wide: \(before) → \(wide)")
        try await resize(opened, width: 400, height: 874)
        let back = try middleOfScreen(opened)
        #expect(back.path == before.path, "back to 400: \(before) → \(back)")
        #expect(abs(back.fraction - before.fraction) < 0.02, "back to 400: \(before) → \(back)")
        #expect(opened.chapterKey == "c2")
        await opened.close()
    }
}

// MARK: - SUWA-18 U1 (upstream #1116): a new reader takes the reader's size
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// The reading mode changes while the reader is not at the screen's size (split view, a window, iPhone Duo):
    /// the new reader's view takes the reader's size, and keeps following it when the window changes again.
    @Test func aNewReaderTakesTheReadersSize() async throws {
        let opened = try await open(mangaKey: "tamanolector", startPage: 2)
        try await resize(opened, width: 600, height: 874)
        opened.reader.setReadingMode("vertical")
        try await Task.sleep(for: .milliseconds(500))
        let paged: UIViewController = try #require(opened.reader.reader, "no reader")
        #expect(paged.view.frame == opened.reader.view.bounds, "paged: \(paged.view.frame) in \(opened.reader.view.bounds)")
        opened.reader.setReadingMode("webtoon")
        try await Task.sleep(for: .seconds(1))
        let webtoon = try #require(opened.reader.reader as? ReaderWebtoonViewController, "not the webtoon reader")
        #expect(webtoon.view.frame == opened.reader.view.bounds, "webtoon: \(webtoon.view.frame) in \(opened.reader.view.bounds)")
        try await resize(opened, width: 500, height: 874)
        #expect(webtoon.view.frame == opened.reader.view.bounds, "after resizing: \(webtoon.view.frame) in \(opened.reader.view.bounds)")
        await opened.close()
    }
}

// MARK: - SUWA-18 U2 (upstream #1116): the rotation anchor follows its page
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// The user goes up to the start of chapter 2 and the anchor is there; chapter 1 goes in above: the anchor is
    /// still chapter 2's item (now in the second section), not chapter 1's. SUWA-19: the reader's anchor is by
    /// chapter, and it is what a size transition puts back (before, the layout's own anchor from #1116, by node,
    /// taken in chapter 2's page 3)
    @Test func theTransitionAnchorFollowsItsPageWhenAChapterGoesInAbove() async throws {
        let opened = try await open(mangaKey: "anclanodo", startPage: 2)
        let webtoon = opened.webtoon
        let layout = try #require(webtoon.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout)
        try userScrolls(opened, toRow: 3, section: 0)
        try await Task.sleep(for: .seconds(2))
        try #require(opened.lastSection == 0 && opened.middle == IndexPath(row: 3, section: 0),
                     "not at chapter 2's page 3: \(String(describing: opened.middle))")
        try userScrolls(opened, toRow: 0, section: 0)
        let anchor = try #require(webtoon.anchor, "no anchor")
        try #require(anchor.chapterKey == "c2" && anchor.item == 0, "the anchor is not chapter 2's start: \(anchor)")
        try await waitForThePreviousChapter(opened)
        try #require(opened.lastSection == 1, "chapter 1 did not go in above")
        #expect(webtoon.anchor?.chapterKey == "c2" && webtoon.anchor?.item == 0, "the anchor moved: \(String(describing: webtoon.anchor))")
        let offset = layout.anchorOffset()
        let target = try #require(webtoon.anchor)
        let middle = offset.map { $0.y + webtoon.collectionNode.bounds.height * target.screenFraction }
        let path = middle.flatMap { y in
            layout.layoutAttributesForElements(in: CGRect(x: 0, y: y, width: 1, height: 1))?
                .first { $0.representedElementCategory == .cell }?.indexPath
        }
        #expect(path == IndexPath(row: 0, section: 1), "the anchor points at \(String(describing: path))")
        await opened.close()
    }
}

// MARK: - SUWA-18 U3 (upstream #1116): size transitions, one or two overlapping
/// A size transition whose animations and completion run when the test says (the simulator can't rotate).
@MainActor
final class SteppedTransitionCoordinator: NSObject, UIViewControllerTransitionCoordinator {
    private var animations: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []
    private var completions: [(any UIViewControllerTransitionCoordinatorContext) -> Void] = []
    let containerView = UIView()

    var isAnimated: Bool { true }
    var presentationStyle: UIModalPresentationStyle { .none }
    var initiallyInteractive: Bool { false }
    var isInterruptible: Bool { false }
    var isInteractive: Bool { false }
    var isCancelled: Bool { false }
    var transitionDuration: TimeInterval { 0.3 }
    var percentComplete: CGFloat { 0 }
    var completionVelocity: CGFloat { 1 }
    var completionCurve: UIView.AnimationCurve { .easeInOut }
    var targetTransform: CGAffineTransform { .identity }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }

    func animate(
        alongsideTransition animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
        completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)? = nil
    ) -> Bool {
        if let animation { animations.append(animation) }
        if let completion { completions.append(completion) }
        return true
    }

    func animateAlongsideTransition(
        in view: UIView?,
        animation: ((any UIViewControllerTransitionCoordinatorContext) -> Void)?,
        completion: ((any UIViewControllerTransitionCoordinatorContext) -> Void)? = nil
    ) -> Bool {
        animate(alongsideTransition: animation, completion: completion)
    }

    @available(iOS, deprecated: 10.0)
    func notifyWhenInteractionEnds(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}
    func notifyWhenInteractionChanges(_ handler: @escaping (any UIViewControllerTransitionCoordinatorContext) -> Void) {}

    func runAnimations() {
        let pending = animations
        animations = []
        pending.forEach { $0(self) }
    }

    func complete() {
        let pending = completions
        completions = []
        pending.forEach { $0(self) }
    }
}

extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// The webtoon is told the size will change, the window takes it, the animations run and it lays out.
    private func transition(_ opened: Opened, to size: CGSize) -> SteppedTransitionCoordinator {
        let coordinator = SteppedTransitionCoordinator()
        opened.webtoon.viewWillTransition(to: size, with: coordinator)
        opened.window.frame = CGRect(origin: .zero, size: size)
        coordinator.runAnimations()
        opened.window.layoutIfNeeded()
        return coordinator
    }

    /// Turned once (portrait → landscape): the page in the middle of the screen stays there.
    @Test func aSizeTransitionKeepsTheMiddlePage() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "ungiro", page: 3, width: 402, height: 874)
        let before = try middleOfScreen(opened)
        transition(opened, to: CGSize(width: 874, height: 402)).complete()
        try await Task.sleep(for: .seconds(1))
        let after = try middleOfScreen(opened)
        #expect(after.path == before.path, "\(before) → \(after)")
        #expect(abs(after.fraction - before.fraction) < 0.02, "\(before) → \(after)")
        #expect(opened.chapterKey == "c2")
        await opened.close()
    }

    /// Switching apps on iPhone Duo: to the other display's size and back, the second transition starting
    /// before the first one completes. The page in the middle of the screen stays there.
    @Test func twoOverlappingSizeTransitionsKeepTheMiddlePage() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "dosgiros", page: 3, width: 402, height: 874)
        let before = try middleOfScreen(opened)
        let first = transition(opened, to: CGSize(width: 874, height: 402))
        let second = transition(opened, to: CGSize(width: 402, height: 874))
        first.complete()
        second.complete()
        try await Task.sleep(for: .seconds(1))
        let after = try middleOfScreen(opened)
        #expect(after.path == before.path, "\(before) → \(after)")
        #expect(abs(after.fraction - before.fraction) < 0.02, "\(before) → \(after)")
        #expect(opened.chapterKey == "c2")
        #expect(opened.reader.currentPage == 3)
        await opened.close()
    }
}

// MARK: - SUWA-19 paso 5: the chapter is the anchor's
extension ImagePipelineSwappingTests.ReaderWebtoonScrollUpTests {
    /// The user goes into chapter 1: the anchor and the reader are in it. The content then moves into chapter 2
    /// without the user (a layout, UIKit): neither the anchor nor the chapter change, and the screen is back on it.
    @Test func theChapterIsTheAnchorsChapter() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "capituloancla", page: 3, width: 402, height: 874)
        let page = try frame(opened, row: 5, section: 0)
        drag(opened, middleAt: page.midY)
        try await Task.sleep(for: .seconds(2))
        #expect(opened.webtoon.anchor?.chapterKey == "c1")
        #expect(opened.chapterKey == "c1")
        let second = try frame(opened, row: 3, section: 1)
        let height = opened.webtoon.collectionNode.bounds.height
        opened.webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: second.midY - height / 2), animated: false)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.webtoon.anchor?.chapterKey == "c1")
        #expect(opened.chapterKey == "c1")
        #expect(opened.middle?.section == 0, "the screen is not back in chapter 1: \(String(describing: opened.middle))")
        await opened.close()
    }

    /// During a drag, a layout pass that moves the content (cells growing above) is not the user going up or
    /// down inside the chapter: only the anchor moving is (before, the offset's change was).
    @Test func aLayoutPassDuringADragIsNotMovingInsideTheChapter() async throws {
        let opened = try await openInTheSecondChapter(mangaKey: "arrastrelayout", page: 3, width: 402, height: 874)
        let webtoon = opened.webtoon
        try userScrolls(opened, toRow: 4, section: opened.lastSection)
        try await Task.sleep(for: .seconds(1))
        let before = try #require(webtoon.anchor, "no anchor")
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.collectionNode.collectionViewLayout.invalidateLayout()
        webtoon.collectionNode.view.layoutIfNeeded()
        webtoon.scrollViewDidScroll(webtoon.scrollView)
        let after = try #require(webtoon.anchor, "no anchor")
        #expect(after.chapterKey == before.chapterKey && after.item == before.item, "\(before) → \(after)")
        #expect(abs(after.fraction - before.fraction) < 0.001, "\(before) → \(after)")
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
        #expect(opened.chapterKey == "c2")
        await opened.close()
    }
}
