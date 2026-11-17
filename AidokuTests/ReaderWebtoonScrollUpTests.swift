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
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
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
        return Opened(reader: reader, webtoon: webtoon, chapterId: chapterId, window: window, directory: directory, modeKey: modeKey)
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
