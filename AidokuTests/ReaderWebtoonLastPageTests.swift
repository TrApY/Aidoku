//
//  ReaderWebtoonLastPageTests.swift
//  AidokuTests
//
//  SUWA-17 B in the webtoon reader: at the last page the chapter is not completed (it opens there again); going
//  on into the transition after it completes it. Through the real ReaderViewController and webtoon reader.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Testing
import UIKit

@testable import Aidoku

@MainActor
@Suite(.serialized) struct ReaderWebtoonLastPageTests {
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
        let window: UIWindow
        let directory: URL

        func close() {
            window.isHidden = true
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private let manga = AidokuRunner.Manga(
        sourceKey: "lectorultima", key: "webtoon", title: "Webtoon", chapters: [AidokuRunner.Chapter(key: "c1", chapterNumber: 1)]
    )
    private var chapterId: ChapterIdentifier { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1") }
    private var modeKey: String { "Reader.readingMode.\(manga.identifier)" }

    /// Opens the chapter at its stored page, the way the reader opens it.
    private func open() async throws -> Opened {
        let chapter = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ultima-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key, in: directory)
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
        return Opened(reader: reader, webtoon: webtoon, window: window, directory: directory)
    }

    /// The user drags until the middle of the screen is in `row` and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int) throws {
        let webtoon = opened.webtoon
        let frame = try #require(
            webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: 0))?.frame
        )
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: frame.midY - webtoon.collectionNode.bounds.height / 2), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
    }

    @Test func atTheLastPageLeavingAndComingBackOpensItAgain() async throws {
        await removeTestHistory(chapterId)
        await DataRepositories.shared.history.savePage(PageSave(chapter: chapterId, page: Self.pageCount - 1, totalPages: Self.pageCount))
        let first = try await open()
        try userScrolls(first, toRow: Self.pageCount)
        try await Task.sleep(for: .seconds(3))
        var stored = await storedProgress(chapterId)
        #expect(stored.progress == Self.pageCount)
        #expect(stored.completed == false)
        first.close()

        // back in: the same chapter, at its last page, still not completed
        let again = try await open()
        #expect(again.reader.currentPage == Self.pageCount)
        stored = await storedProgress(chapterId)
        #expect(stored.completed == false)

        // on past the last page, into the «no more chapters» transition: completed
        try userScrolls(again, toRow: Self.pageCount + 1)
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(chapterId).completed == true)
        again.close()
        UserDefaults.standard.removeObject(forKey: modeKey)
        await removeTestHistory(chapterId)
    }
}
