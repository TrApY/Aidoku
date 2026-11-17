//
//  ReaderReturnPositionTests.swift
//  AidokuTests
//
//  SUWA-17 D (JoTa, 17-nov): coming back to a manga (Continuar leyendo from its screen, the Library or the History,
//  or opening the reader again) it is at the LAST PLACE the user was: chapter and page. Through the real
//  ReaderViewController (the paged reader's page reports, and the webtoon reader with its pages).
//

import AidokuRunner
import Foundation
import Testing
import UIKit

@testable import Aidoku

@MainActor
@Suite(.serialized) struct ReaderReturnPositionTests {
    static let pageCount = 12
    let c1 = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
    let c2 = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)
    let c3 = AidokuRunner.Chapter(key: "c3", chapterNumber: 3)

    func id(_ manga: AidokuRunner.Manga, _ chapter: AidokuRunner.Chapter) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
    }

    /// A page stored for the chapter, as the reader stores it.
    func seed(_ chapter: ChapterIdentifier, page: Int, total: Int) async {
        await DataRepositories.shared.history.savePage(PageSave(chapter: chapter, page: page, totalPages: total))
    }

    func complete(_ chapter: ChapterIdentifier) async {
        await DataRepositories.shared.history.markCompleted([chapter], date: Date())
    }

    func stored(_ chapter: ChapterIdentifier) async -> HistoryRecord? {
        await DataRepositories.shared.history.record(of: chapter)
    }

    /// The completions the history wrote to the journal for a chapter (not the readers' own notes).
    func journaled(_ chapter: ChapterIdentifier) -> Int {
        CompletionJournal.lines().filter {
            let fields = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.count >= 5 && fields[1] == chapter.sourceKey && fields[2] == chapter.mangaKey
                && fields[3] == chapter.chapterKey && !fields[4].hasPrefix("webtoon:")
        }.count
    }

    /// Whether the chapter is completed, waiting up to 5 s for the history to be saved.
    func completed(_ chapter: ChapterIdentifier) async -> Bool {
        for _ in 0..<20 {
            if await storedProgress(chapter).completed { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    func manga(_ key: String, _ chapters: [AidokuRunner.Chapter]) -> AidokuRunner.Manga {
        AidokuRunner.Manga(sourceKey: "lectorvolver", key: key, title: "Volver", chapters: chapters)
    }

    func pages(_ manga: AidokuRunner.Manga, _ chapter: AidokuRunner.Chapter, count: Int = 38) -> [Aidoku.Page] {
        (0..<count).map { Aidoku.Page(sourceId: manga.sourceKey, chapterId: chapter.key, index: $0, imageURL: "https://example.invalid/\($0).jpg") }
    }

    /// The paged reader on `chapter` without a window: its page reports are the test's (as ReaderChapterEndTests).
    func paged(_ manga: AidokuRunner.Manga, on chapter: AidokuRunner.Chapter) async -> ReaderViewController {
        let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        reader.loadViewIfNeeded()
        try? await Task.sleep(for: .seconds(1))
        reader.presentedViewController?.dismiss(animated: false)
        reader.setPages(pages(manga, chapter))
        return reader
    }

    /// The paged reader on `chapter` opened at its stored page, as when the user comes back to it.
    func pagedOpened(_ manga: AidokuRunner.Manga, on chapter: AidokuRunner.Chapter) async -> ReaderViewController {
        let reader = await paged(manga, on: chapter)
        reader.loadCurrentChapter()
        // the chapter load (no source in the test) ends empty a moment later: then its pages again
        try? await Task.sleep(for: .seconds(2))
        reader.setPages(pages(manga, chapter))
        return reader
    }

    @MainActor
    struct Webtoon {
        let reader: ReaderViewController
        let webtoon: ReaderWebtoonViewController
        let window: UIWindow
        let directory: URL
        let modeKey: String
        let manga: AidokuRunner.Manga

        func close() async {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
            await DataRepositories.shared.history.removeAll(of: manga.identifier)
        }

        /// What the reader gets when it asks for `chapter`.
        func ready(_ chapter: AidokuRunner.Chapter) {
            webtoon.viewModel.preloadedChapter = chapter
            webtoon.viewModel.preloadedPages = (try? ReaderReturnPositionTests.files(manga, chapter, in: directory)) ?? []
        }
    }

    /// Page images as files (a downloaded chapter): quick to load.
    static func files(_ manga: AidokuRunner.Manga, _ chapter: AidokuRunner.Chapter, in directory: URL) throws -> [Aidoku.Page] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return try (0..<pageCount).map { index in
            let url = directory.appendingPathComponent("\(chapter.key)-\(index).jpg")
            if !FileManager.default.fileExists(atPath: url.path) {
                let data = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 900), format: format).jpegData(withCompressionQuality: 0.5) {
                    UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
                    $0.fill(CGRect(x: 0, y: 0, width: 400, height: 900))
                }
                try data.write(to: url)
            }
            return Aidoku.Page(sourceId: manga.sourceKey, chapterId: chapter.key, index: index, imageURL: url.absoluteString)
        }
    }

    /// The webtoon reader opening `chapter` at its stored page, in a window.
    func webtoon(_ manga: AidokuRunner.Manga, on chapter: AidokuRunner.Chapter) async throws -> Webtoon {
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("volver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let opened = Webtoon(reader: reader, webtoon: webtoon, window: window, directory: directory, modeKey: modeKey, manga: manga)
        opened.ready(chapter)
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(4))
        return opened
    }
}

// MARK: - D1: «previous / next chapter» open the chapter where it was left
extension ReaderReturnPositionTests {
    /// Chapter 2 at page 2 → «previous chapter» to chapter 1, stored at page 10: it opens at 10, and that page is
    /// not written over (nothing is saved until the user moves).
    @Test func previousChapterOpensAtItsStoredPageAndKeepsIt() async throws {
        let manga = manga("anterior", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c1), page: 10, total: Self.pageCount)
        await seed(id(manga, c2), page: 2, total: Self.pageCount)
        let opened = try await webtoon(manga, on: c2)
        try #require(opened.reader.currentPage == 2, "chapter 2 opened at \(opened.reader.currentPage)")
        opened.ready(c1)
        opened.reader.previousChapter()
        try await Task.sleep(for: .seconds(4))
        #expect(opened.reader.chapter.key == c1.key)
        #expect(opened.reader.currentPage == 10, "chapter 1 opened at \(opened.reader.currentPage)")
        #expect(await stored(id(manga, c1))?.progress == 10)
        #expect(await stored(id(manga, c2))?.progress == 2)
        await opened.close()
    }
}
