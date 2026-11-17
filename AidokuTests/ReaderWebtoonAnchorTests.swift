//
//  ReaderWebtoonAnchorTests.swift
//  AidokuTests
//
//  SUWA-19 (ReadingAnchor): where the user is reading is a logical anchor (chapter, item, where in it) that only
//  the user moves; the page the reader reports is the anchor's. Through the real ReaderViewController and webtoon
//  reader, with real images taller than the provisional height.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Testing
import UIKit

@testable import Aidoku

extension ImagePipelineSwappingTests {
@MainActor
@Suite(.serialized) struct ReaderWebtoonAnchorTests {
    private static let pageCount = 38

    /// Pages as image files of 300×900 and 300×860 (about 1200 pt high on screen; the provisional one is ~577).
    private static func pages(sourceKey: String, chapterKey: String) throws -> (pages: [Aidoku.Page], directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ancla-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<pageCount {
            let size = CGSize(width: 300, height: index % 2 == 0 ? 900 : 860)
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let url = directory.appendingPathComponent("\(index).png")
            try data.write(to: url)
            pages.append(Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, imageURL: url.absoluteString))
        }
        return (pages, directory)
    }

    @MainActor
    struct Opened {
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

        func frame(row: Int, section: Int = 0) throws -> CGRect {
            try #require(webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: section))?.frame)
        }
    }

    /// Opens chapter "c1" in the webtoon reader at the stored page `startPage`; `wait` seconds for the images.
    private func open(mangaKey: String, startPage: Int, wait: Double = 5) async throws -> Opened {
        let manga = AidokuRunner.Manga(sourceKey: "lectorancla", key: mangaKey, title: "Webtoon")
        let chapter = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let chapterId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        await removeTestHistory(chapterId)
        await DataRepositories.shared.history.savePage(PageSave(chapter: chapterId, page: startPage, totalPages: Self.pageCount))
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let (pages, directory) = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key)

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
        try await Task.sleep(for: .seconds(wait))
        return Opened(reader: reader, webtoon: webtoon, chapterId: chapterId, window: window, directory: directory, modeKey: modeKey)
    }

    /// The user drags until the middle of the screen is at `fraction` of `row`, and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int, at fraction: CGFloat = 0.5) throws {
        let webtoon = opened.webtoon
        let frame = try opened.frame(row: row)
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        let y = frame.minY + frame.height * fraction - webtoon.collectionNode.bounds.height / 2
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
    }

    // MARK: - Paso 2: the reader keeps the anchor, only the user moves it, the page comes from it

    /// D4: the chapter opens with the top of the stored page at the top of the screen.
    @Test func openingSetsTheAnchorAtTheTopOfTheStartPage() async throws {
        let opened = try await open(mangaKey: "anclaabrir", startPage: 5)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after opening")
        #expect(anchor.chapterKey == "c1")
        #expect(anchor.item == 5)
        #expect(anchor.fraction == 0)
        #expect(anchor.screenFraction == 0)
        await opened.close()
    }

    /// The user drags: the anchor is the item in the middle of the screen and where in it.
    @Test func aDragChangesTheAnchorToTheMiddleOfTheScreen() async throws {
        let opened = try await open(mangaKey: "anclaarrastre", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.3)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after a drag")
        #expect(anchor.chapterKey == "c1")
        #expect(anchor.item == 7)
        #expect(abs(anchor.fraction - 0.3) < 0.01, "fraction \(anchor.fraction)")
        #expect(anchor.screenFraction == 0.5)
        #expect(anchor.measured)
        await opened.close()
    }

    /// I1: the content moving without the user (a layout pass, UIKit) does not change the anchor.
    @Test func aLayoutMoveDoesNotChangeTheAnchor() async throws {
        let opened = try await open(mangaKey: "anclalayout", startPage: 5)
        try userScrolls(opened, toRow: 6)
        try await Task.sleep(for: .milliseconds(500))
        let before = try #require(opened.webtoon.anchor, "no anchor after a drag")
        let scrollView = opened.webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y + 700), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(opened.webtoon.anchor == before)
        await opened.close()
    }

    /// I3: the page reported is the anchor's: the content moving to page 8 without the user reports nothing.
    @Test func theReportedPageIsTheAnchorsPage() async throws {
        let opened = try await open(mangaKey: "anclapagina", startPage: 5)
        try userScrolls(opened, toRow: 6)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.currentPage == 6, "the drag did not report page 6: \(opened.reader.currentPage)")
        let target = try opened.frame(row: 8)
        let scrollView = opened.webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: target.midY - opened.webtoon.collectionNode.bounds.height / 2), animated: false)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.reader.currentPage == 6)
        await opened.close()
    }
}
}
