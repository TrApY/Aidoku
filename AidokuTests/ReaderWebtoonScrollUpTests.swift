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

    @Test func scrollingUpInsideTheChapterStaysInItAndOnThePage() async throws {
        let opened = try await open(mangaKey: "subir", startPage: 8)
        #expect(opened.chapterKey == "c2")
        for page in stride(from: 7, through: 1, by: -1) {
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
        try await Task.sleep(for: .seconds(4))
        #expect(opened.lastSection == 1, "the previous chapter was not put in")
        #expect(opened.chapterKey == "c2")
        #expect(opened.middle == IndexPath(row: 0, section: opened.lastSection))
        #expect(opened.reader.currentPage == 1)
        await opened.close()
    }

    @Test func goingUpPastTheFirstPageChangesToThePreviousChapter() async throws {
        let opened = try await open(mangaKey: "subirycambiar", startPage: 2)
        try userScrolls(opened, toRow: 0, section: opened.lastSection)
        try await Task.sleep(for: .seconds(4))
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
