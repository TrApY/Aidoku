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

extension ImagePipelineSwappingTests {
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

    /// A completed chapter read again for real: completed (and journaled on this device) two minutes ago, opened
    /// again a minute ago in a session with pages read, and left at `page` (SUWA-17 F2).
    func reread(_ chapter: ChapterIdentifier, page: Int, total: Int) async {
        let completedAt = Date().addingTimeInterval(-120)
        await seed(chapter, page: total, total: total)
        await DataRepositories.shared.history.markCompleted([chapter], date: completedAt)
        CompletionJournal.record(chapter, reason: "test: completado", date: completedAt)
        await DataRepositories.shared.sessions.add(
            .init(startDate: Date().addingTimeInterval(-60), endDate: Date().addingTimeInterval(-30), pagesRead: 3),
            chapter: chapter
        )
        await seed(chapter, page: page, total: total)
    }

    /// A chapter completed with a page before its last one that was not read again: completed (not on this
    /// device: a sync, the other device) and its page saved after (SUWA-17 F2).
    func oldPartialCompletion(_ chapter: ChapterIdentifier, page: Int, total: Int) async {
        await seed(chapter, page: total, total: total)
        await complete(chapter)
        await seed(chapter, page: page, total: total)
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
}

// MARK: - D1: «previous / next chapter» open the chapter where it was left
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
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

// MARK: - D2: a completed chapter read again
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// «Continuar»: a completed chapter being read again (0 < page < total, the latest read) is the one; a completed
    /// one read to its end is not (the next one is); a chapter not completed, read last, is the one.
    @Test func continueGoesToTheChapterBeingReadAgain() async throws {
        let again = manga("releer", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: again.identifier)
        await reread(id(again, c1), page: 5, total: Self.pageCount)
        let (_, rereading) = await MangaManager.shared.getNextChapter(mangaId: again.identifier, fallbackChapters: [c2, c1])
        #expect(rereading?.key == c1.key, "a completed chapter read again at page 5: \(String(describing: rereading?.key))")

        let finished = manga("terminado", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: finished.identifier)
        await seed(id(finished, c1), page: Self.pageCount, total: Self.pageCount)
        await complete(id(finished, c1))
        let (_, next) = await MangaManager.shared.getNextChapter(mangaId: finished.identifier, fallbackChapters: [c2, c1])
        #expect(next?.key == c2.key, "after finishing chapter 1: \(String(describing: next?.key))")

        let reading = manga("leyendo", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: reading.identifier)
        await seed(id(reading, c2), page: Self.pageCount, total: Self.pageCount)
        await complete(id(reading, c2))
        try await Task.sleep(for: .milliseconds(1100))
        await seed(id(reading, c1), page: 5, total: Self.pageCount)
        let (_, current) = await MangaManager.shared.getNextChapter(mangaId: reading.identifier, fallbackChapters: [c2, c1])
        #expect(current?.key == c1.key, "chapter 1 at page 5, read last: \(String(describing: current?.key))")

        for manga in [again, finished, reading] {
            await DataRepositories.shared.history.removeAll(of: manga.identifier)
        }
    }

    /// Completing a chapter leaves it at its last page, so a completed chapter is not taken as one being read again
    /// (also when it is marked as read from the manga's screen).
    @Test func completingLeavesTheChapterAtItsLastPage() async throws {
        let manga = manga("completar", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c1), page: 7, total: Self.pageCount)
        await HistoryManager.shared.addHistory(mangaId: manga.identifier, chapters: [c1], reason: "test")
        let record = await stored(id(manga, c1))
        #expect(record?.completed == true)
        #expect(record?.progress == Self.pageCount, "completed at page \(String(describing: record?.progress))")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// The reader opens a completed chapter being read again at its page; reading on keeps it completed (nothing
    /// goes to the server as unread: the page trackers only get pages of chapters not completed).
    @Test func theReaderOpensAChapterBeingReadAgainAtItsPage() async throws {
        let manga = manga("reabrir", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await reread(id(manga, c1), page: 5, total: Self.pageCount)
        let opened = try await webtoon(manga, on: c1)
        #expect(opened.reader.currentPage == 5, "opened at \(opened.reader.currentPage)")
        opened.reader.setCurrentPage(6, position: nil)
        try await Task.sleep(for: .seconds(3))
        let record = await stored(id(manga, c1))
        #expect(record?.completed == true)
        #expect(record?.progress == 6)
        await opened.close()
    }
}

// MARK: - D3: leaving the reader
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// Opened at page 10 and left without moving: nothing is written (another device, through iCloud, may have
    /// saved a newer page meanwhile).
    @Test func leavingAtTheOpeningPageWritesNothing() async throws {
        let manga = manga("salirsintocar", [c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c1), page: 10, total: 38)
        let reader = await pagedOpened(manga, on: c1)
        try #require(reader.currentPage == 10, "opened at \(reader.currentPage)")
        // the other device's newer page comes in
        await seed(id(manga, c1), page: 15, total: 38)
        reader.viewWillDisappear(false)
        try await Task.sleep(for: .seconds(1))
        #expect(await stored(id(manga, c1))?.progress == 15)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// Opened at page 10, back to page 5 and left at once: page 5 is written.
    @Test func leavingAfterMovingWritesThePage() async throws {
        let manga = manga("salirmoviendo", [c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c1), page: 10, total: 38)
        let reader = await pagedOpened(manga, on: c1)
        try #require(reader.currentPage == 10, "opened at \(reader.currentPage)")
        reader.setCurrentPage(5, position: nil)
        reader.viewWillDisappear(false)
        try await Task.sleep(for: .seconds(1))
        #expect(await stored(id(manga, c1))?.progress == 5)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// The chapter changes by scrolling (no chapterOpened there): the page saved on the way out is the last one
    /// saved, so coming back to the opening page is a change and is saved.
    @Test func afterAChapterChangeTheSavedPageIsTheLastOneSaved() async throws {
        let manga = manga("cambio", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c2), page: 10, total: 38)
        let reader = await pagedOpened(manga, on: c2)
        try #require(reader.currentPage == 10, "opened at \(reader.currentPage)")
        reader.setCurrentPage(11, position: nil)
        // up into chapter 1 and straight back down (the readers tell both)
        reader.setChapter(c1)
        reader.setChapter(c2)
        reader.setPages(pages(manga, c2))
        reader.setCurrentPage(10, position: nil)
        try await Task.sleep(for: .seconds(3))
        #expect(await stored(id(manga, c2))?.progress == 10)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }
}

// MARK: - D5: a chapter entered from below
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// Up from the start of chapter 2 into the last page of chapter 1 and down again: chapter 1 is not completed
    /// (it was not read going down).
    @Test func upIntoThePreviousChapterAndDownAgainCompletesNothing() async throws {
        let manga = manga("subirybajar", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        let before = journaled(id(manga, c1))
        let reader = await paged(manga, on: c2)
        reader.setCurrentPage(1, position: nil)
        reader.setChapter(c1)
        reader.setPages(pages(manga, c1))
        reader.setCurrentPage(38, position: nil)
        reader.setCurrentPage(39, position: nil)
        reader.setChapter(c2)
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(id(manga, c1)).completed == false)
        #expect(journaled(id(manga, c1)) - before == 0)
        #expect(await stored(id(manga, c1)) == nil, "chapter 1 saved without reading it")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// From below, up into its pages and then read down to its end: completed, as always.
    @Test func upIntoItsPagesAndReadDownCompletes() async throws {
        let manga = manga("subirleer", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        let reader = await paged(manga, on: c2)
        reader.setCurrentPage(1, position: nil)
        reader.setChapter(c1)
        reader.setPages(pages(manga, c1))
        reader.setCurrentPage(38, position: nil)
        reader.setCurrentPage(30, position: nil)
        for page in 31...39 {
            reader.setCurrentPage(page, position: nil)
        }
        #expect(await completed(id(manga, c1)) == true)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }
}

// MARK: - D6: the last page seen counts for the visit
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// The last page of chapter 2 seen, «previous» to chapter 1, back to chapter 2 and «next» from its page 3:
    /// chapter 2 is not completed (its last page was seen in an earlier visit).
    @Test func theLastPageSeenInAnEarlierVisitDoesNotCount() async throws {
        let manga = manga("visita", [c3, c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        let reader = await paged(manga, on: c2)
        reader.setCurrentPage(37, position: nil)
        reader.setCurrentPage(38, position: nil)
        reader.setChapter(c1)
        reader.setPages(pages(manga, c1))
        reader.setCurrentPage(1, position: nil)
        reader.setChapter(c2)
        reader.setPages(pages(manga, c2))
        reader.setCurrentPage(3, position: nil)
        reader.setChapter(c3)
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(id(manga, c2)).completed == false)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }
}

// MARK: - SUWA-17 F1: «Continuar» takes up a chapter read again only if it is the last one read
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// Chapter 1 (completed) read again up to page 10; then chapter 3 read to its end and chapter 4 opened and
    /// left at its first page (nothing saved): «Continuar» opens chapter 4, not chapter 1.
    @Test func continueGoesToTheLastChapterReadNotToAnOlderReread() async throws {
        let c4 = AidokuRunner.Chapter(key: "c4", chapterNumber: 4)
        let manga = manga("f1", [c4, c3, c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await complete(id(manga, c2))
        await reread(id(manga, c1), page: 10, total: Self.pageCount)
        try await Task.sleep(for: .milliseconds(1100))
        await seed(id(manga, c3), page: Self.pageCount, total: Self.pageCount)
        await complete(id(manga, c3))
        let (_, next) = await MangaManager.shared.getNextChapter(mangaId: manga.identifier, fallbackChapters: [c4, c3, c2, c1])
        #expect(next?.key == c4.key, "«Continuar» opens \(String(describing: next?.key))")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }
}

// MARK: - SUWA-17 F2: completed chapters with a partial page that were not read again
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// Completed elsewhere (a sync, the other device) with a page before its last one; or completed here right
    /// after its last session (the old relayout, «marcar como leído» after reading some of it); or read again but
    /// left at its last but one page: not taken up, «Continuar» goes on as before.
    @Test func oldCompletedChaptersWithAPartialPageAreNotTakenUp() async throws {
        let synced = manga("f2sinc", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: synced.identifier)
        await oldPartialCompletion(id(synced, c1), page: 5, total: Self.pageCount)
        var (_, next) = await MangaManager.shared.getNextChapter(mangaId: synced.identifier, fallbackChapters: [c2, c1])
        #expect(next?.key == c2.key, "completed elsewhere: \(String(describing: next?.key))")

        let here = manga("f2aqui", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: here.identifier)
        await DataRepositories.shared.sessions.add(
            .init(startDate: Date().addingTimeInterval(-90), endDate: Date().addingTimeInterval(-80), pagesRead: 3),
            chapter: id(here, c1)
        )
        let completedAt = Date().addingTimeInterval(-60)
        await DataRepositories.shared.history.markCompleted([id(here, c1)], date: completedAt)
        CompletionJournal.record(id(here, c1), reason: "test: completado", date: completedAt)
        await seed(id(here, c1), page: 5, total: Self.pageCount)
        (_, next) = await MangaManager.shared.getNextChapter(mangaId: here.identifier, fallbackChapters: [c2, c1])
        #expect(next?.key == c2.key, "completed here after its last session: \(String(describing: next?.key))")

        let lastButOne = manga("f2penultima", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: lastButOne.identifier)
        await reread(id(lastButOne, c1), page: Self.pageCount - 1, total: Self.pageCount)
        (_, next) = await MangaManager.shared.getNextChapter(mangaId: lastButOne.identifier, fallbackChapters: [c2, c1])
        #expect(next?.key == c2.key, "at its last but one page: \(String(describing: next?.key))")

        for manga in [synced, here, lastButOne] {
            await DataRepositories.shared.history.removeAll(of: manga.identifier)
        }
    }

    /// A manga all read, one of them completed long ago with a partial page: «Continuar» as before (no chapter
    /// to go on with).
    @Test func allReadWithAnOldPartialCompletionContinuesAsBefore() async throws {
        let manga = manga("f2todo", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await oldPartialCompletion(id(manga, c1), page: 5, total: Self.pageCount)
        try await Task.sleep(for: .milliseconds(1100))
        await seed(id(manga, c2), page: Self.pageCount, total: Self.pageCount)
        await complete(id(manga, c2))
        let (_, next) = await MangaManager.shared.getNextChapter(mangaId: manga.identifier, fallbackChapters: [c2, c1])
        #expect(next == nil, "all read: \(String(describing: next?.key))")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// The reader opens a chapter completed long ago with a partial page at its start, as before.
    @Test func theReaderOpensAnOldPartialCompletionAtItsStart() async throws {
        let manga = manga("f2lector", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await oldPartialCompletion(id(manga, c1), page: 5, total: Self.pageCount)
        let opened = try await webtoon(manga, on: c1)
        #expect(opened.reader.currentPage == 1, "opened at \(opened.reader.currentPage)")
        await opened.close()
    }
}

// MARK: - SUWA-17 F5: «siguiente» and the paged reader
extension ImagePipelineSwappingTests.ReaderReturnPositionTests {
    /// Chapter 1 at page 2 → «next chapter» to chapter 2, stored at page 10: it opens at 10 and keeps it.
    @Test func nextChapterOpensAtItsStoredPageAndKeepsIt() async throws {
        let manga = manga("siguiente", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c1), page: 2, total: Self.pageCount)
        await seed(id(manga, c2), page: 10, total: Self.pageCount)
        let opened = try await webtoon(manga, on: c1)
        try #require(opened.reader.currentPage == 2, "chapter 1 opened at \(opened.reader.currentPage)")
        opened.ready(c2)
        opened.reader.nextChapter()
        try await Task.sleep(for: .seconds(4))
        #expect(opened.reader.chapter.key == c2.key)
        #expect(opened.reader.currentPage == 10, "chapter 2 opened at \(opened.reader.currentPage)")
        #expect(await stored(id(manga, c2))?.progress == 10)
        #expect(await stored(id(manga, c1))?.progress == 2)
        await opened.close()
    }

    /// The paged reader (left to right), in a window: chapter 2 at page 2 → «previous» to chapter 1 stored at
    /// page 10 (it opened at the last page before D1) → opens at 10 and keeps it; and «next» back to chapter 2 at 2.
    @Test func thePagedReaderOpensPreviousAndNextAtTheirStoredPages() async throws {
        let manga = manga("paginado", [c2, c1])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await seed(id(manga, c1), page: 10, total: Self.pageCount)
        await seed(id(manga, c2), page: 2, total: Self.pageCount)
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("ltr", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paginado-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
        }
        let reader = ReaderViewController(source: nil, manga: manga, chapter: c2)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let paged = try #require(reader.reader as? ReaderPagedViewController, "not the paged reader")
        reader.presentedViewController?.dismiss(animated: false)
        paged.viewModel.preloadedChapter = c2
        paged.viewModel.preloadedPages = try Self.files(manga, c2, in: directory)
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(3))
        try #require(reader.currentPage == 2, "chapter 2 opened at \(reader.currentPage)")
        paged.viewModel.preloadedChapter = c1
        paged.viewModel.preloadedPages = try Self.files(manga, c1, in: directory)
        reader.previousChapter()
        try await Task.sleep(for: .seconds(4))
        #expect(reader.chapter.key == c1.key)
        #expect(reader.currentPage == 10, "chapter 1 opened at \(reader.currentPage)")
        #expect(await stored(id(manga, c1))?.progress == 10)
        paged.viewModel.preloadedChapter = c2
        paged.viewModel.preloadedPages = try Self.files(manga, c2, in: directory)
        reader.nextChapter()
        try await Task.sleep(for: .seconds(4))
        #expect(reader.chapter.key == c2.key)
        #expect(reader.currentPage == 2, "chapter 2 opened again at \(reader.currentPage)")
        #expect(await stored(id(manga, c2))?.progress == 2)
        window.isHidden = true
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }
}
