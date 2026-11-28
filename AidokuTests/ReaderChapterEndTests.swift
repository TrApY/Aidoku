//
//  ReaderChapterEndTests.swift
//  AidokuTests
//
//  SUWA-17 B (JoTa, 16-nov): at the last page, leaving and coming back opens the same chapter at its last page; a
//  chapter is completed only when the user goes from its last page to the transition or to the next chapter.
//  Through the real ReaderViewController (the page reports of the paged and webtoon readers).
//

import AidokuRunner
import Foundation
import Testing
import UIKit

@testable import Aidoku

extension ImagePipelineSwappingTests {
@MainActor
@Suite(.serialized) struct ReaderChapterEndTests {
    private static let pageCount = 38
    private let first = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
    private let second = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)

    /// A reader on `chapter` of a manga with chapters 1 and 2 (the source's order, newest first).
    private func reader(
        mangaKey: String,
        chapter: AidokuRunner.Chapter,
        pageCount: Int = ReaderChapterEndTests.pageCount
    ) async -> (ReaderViewController, AidokuRunner.Manga) {
        let manga = AidokuRunner.Manga(sourceKey: "lectorfinal", key: mangaKey, title: "Final", chapters: [second, first])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        // set up as when it opens (loading its view starts a reading session), then the chapter's pages
        reader.loadViewIfNeeded()
        try? await Task.sleep(for: .seconds(1))
        reader.presentedViewController?.dismiss(animated: false)
        reader.setPages((0..<pageCount).map {
            Page(sourceId: manga.sourceKey, chapterId: chapter.key, index: $0, imageURL: "https://example.invalid/\($0).jpg")
        })
        return (reader, manga)
    }

    /// Whether the chapter is completed, waiting up to 5 s for the history to be saved (other suites run at
    /// the same time).
    private func completed(_ chapter: ChapterIdentifier) async -> Bool {
        for _ in 0..<20 {
            if await storedProgress(chapter).completed { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func id(_ manga: AidokuRunner.Manga, _ chapter: AidokuRunner.Chapter) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
    }

    /// The completions the history wrote to the journal for this chapter (not the readers' own notes).
    private func journaled(_ chapter: ChapterIdentifier) -> Int {
        CompletionJournal.lines().filter {
            let fields = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.count >= 5 && fields[1] == chapter.sourceKey && fields[2] == chapter.mangaKey
                && fields[3] == chapter.chapterKey && !fields[4].hasPrefix("webtoon:")
        }.count
    }

    /// The last page, then out: saved as the current page, not completed; «Continuar leyendo» opens this chapter.
    @Test func theLastPageAloneIsSavedAndNotCompleted() async throws {
        let (reader, manga) = await reader(mangaKey: "ultima", chapter: first)
        for page in 36...38 {
            reader.setCurrentPage(page, position: nil)
        }
        try await Task.sleep(for: .seconds(3))
        let stored = await storedProgress(id(manga, first))
        #expect(stored.progress == 38)
        #expect(stored.completed == false)
        // the chapter the manga's screen continues with: this one (it opens at the stored page, 38)
        let history = await DataRepositories.shared.history.readingHistory(of: manga.identifier).pagesAndDates
        let next = MangaManager.shared.getNextChapter(manga: manga, chapters: [second, first], readingHistory: history, sortAscending: false)
        #expect(next?.key == "c1")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// From the last page to the transition: completed, once; back from the transition it stays completed (going
    /// into the transition was going past the last page).
    @Test func goingIntoTheTransitionCompletesOnce() async throws {
        let (reader, manga) = await reader(mangaKey: "transicion", chapter: first)
        let chapterId = id(manga, first)
        let before = journaled(chapterId)
        reader.setCurrentPage(37, position: nil)
        reader.setCurrentPage(38, position: nil)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(chapterId).completed == false)
        reader.setCurrentPage(39, position: nil)
        #expect(await completed(chapterId) == true)
        // back to the last page and into the transition again
        reader.setCurrentPage(38, position: nil)
        reader.setCurrentPage(39, position: nil)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(chapterId).completed == true)
        #expect(journaled(chapterId) - before == 1)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// To the next chapter from its last page (the paged reader turning past the transition, the next chapter
    /// button): the chapter left is completed.
    @Test func toTheNextChapterFromTheLastPageCompletes() async throws {
        let (reader, manga) = await reader(mangaKey: "siguiente", chapter: first)
        reader.setCurrentPage(37, position: nil)
        reader.setCurrentPage(38, position: nil)
        reader.setChapter(second)
        #expect(await completed(id(manga, first)) == true)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// To the next chapter from the middle, or back to the previous one from the last page: nothing completed.
    @Test func otherChapterChangesDoNotComplete() async throws {
        let (reader, manga) = await reader(mangaKey: "otros", chapter: first)
        reader.setCurrentPage(20, position: nil)
        reader.setChapter(second)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(id(manga, first)).completed == false)

        let (back, other) = await self.reader(mangaKey: "atras", chapter: second)
        back.setCurrentPage(37, position: nil)
        back.setCurrentPage(38, position: nil)
        back.setChapter(first)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(id(other, second)).completed == false)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await DataRepositories.shared.history.removeAll(of: other.identifier)
    }

    /// SUWA-17 C1: a reader putting the previous chapter in tells «previous chapter» and then «this chapter»
    /// again (the scrolling text reader does). After the last page of this chapter, that pair completes nothing:
    /// not the previous chapter (never opened), not this one. In the webtoon reader.
    @Test func thePreviousAndBackPairCompletesNothing() async throws {
        let manga = AidokuRunner.Manga(sourceKey: "lectorfinal", key: "par", title: "Final", chapters: [second, first])
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let (reader, _) = await reader(mangaKey: "par", chapter: second)
        #expect(reader.reader is ReaderWebtoonViewController)
        let before = journaled(id(manga, first))
        reader.setCurrentPage(37, position: nil)
        reader.setCurrentPage(38, position: nil)
        reader.setChapter(first)
        reader.setChapter(second)
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(id(manga, first)).completed == false, "the previous chapter, never opened, completed")
        #expect(journaled(id(manga, first)) - before == 0)
        #expect(await storedProgress(id(manga, second)).completed == false)
        UserDefaults.standard.removeObject(forKey: modeKey)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// SUWA-17 C2: into the transition (completed) and then on to the next chapter: one completion, not a
    /// second one when the chapter changes (the download to delete after reading is queued once).
    @Test func intoTheTransitionAndOnToTheNextChapterCompletesOnce() async throws {
        let deleteKey = "Library.deleteDownloadAfterReading"
        let queueKey = "Data.chaptersToBeDeleted"
        UserDefaults.standard.set(true, forKey: deleteKey)
        let (reader, manga) = await reader(mangaKey: "unavez", chapter: first)
        reader.setCurrentPage(37, position: nil)
        reader.setCurrentPage(38, position: nil)
        reader.setCurrentPage(39, position: nil)
        #expect(await completed(id(manga, first)) == true)
        reader.setChapter(second)
        try await Task.sleep(for: .seconds(1))
        let queued = (UserDefaults.standard.data(forKey: queueKey))
            .flatMap { try? JSONDecoder().decode([ChapterIdentifier].self, from: $0) } ?? []
        #expect(queued.filter { $0 == id(manga, first) }.count == 1, "queued for deletion \(queued.count) times")
        UserDefaults.standard.removeObject(forKey: deleteKey)
        UserDefaults.standard.removeObject(forKey: queueKey)
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    // MARK: - SUWA-39 B: in the webtoon a chapter is completed only after going down it

    private static let webtoonPages = 32

    /// The chapter opened in the webtoon reader at the stored page (what «Continuar» does), with 32 pages: the
    /// reader opens it (that is where the descent starts) and, with no source, finds no pages, so they are told after.
    private func openedWebtoon(
        mangaKey: String,
        chapter: AidokuRunner.Chapter,
        page: Int
    ) async throws -> (ReaderViewController, AidokuRunner.Manga) {
        let manga = AidokuRunner.Manga(sourceKey: "lectorfinal", key: mangaKey, title: "Final", chapters: [second, first])
        UserDefaults.standard.set("webtoon", forKey: "Reader.readingMode.\(manga.identifier)")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        await DataRepositories.shared.history.savePage(PageSave(chapter: id(manga, chapter), page: page, totalPages: Self.webtoonPages))
        let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        reader.loadViewIfNeeded()
        try await Task.sleep(for: .seconds(1))
        reader.presentedViewController?.dismiss(animated: false)
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(1))
        reader.presentedViewController?.dismiss(animated: false)
        reader.setPages((0..<Self.webtoonPages).map {
            Page(sourceId: manga.sourceKey, chapterId: chapter.key, index: $0, imageURL: "https://example.invalid/\($0).jpg")
        })
        try #require(reader.reader is ReaderWebtoonViewController, "not the webtoon reader")
        try #require(reader.currentPage == page, "opened at \(reader.currentPage), not at \(page)")
        return (reader, manga)
    }

    private func closeWebtoon(_ manga: AidokuRunner.Manga) async {
        UserDefaults.standard.removeObject(forKey: "Reader.readingMode.\(manga.identifier)")
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
    }

    /// The lines of the journal where the webtoon reader says it did not complete the chapter.
    private func refusals(_ chapter: ChapterIdentifier) -> [String] {
        CompletionJournal.lines().compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard
                fields.count >= 5, fields[1] == chapter.sourceKey, fields[2] == chapter.mangaKey, fields[3] == chapter.chapterKey,
                fields[4].hasPrefix("webtoon: no completa")
            else { return nil }
            return fields[4]
        }
    }

    /// Opened at page 12, the user is put at page 30 of 32 without the slider (a jump: a link, a layout, a stale
    /// anchor) and goes down to the transition: not read, not completed. The journal says why, once.
    @Test func aJumpDownWithoutTheSliderDoesNotComplete() async throws {
        let (reader, manga) = try await openedWebtoon(mangaKey: "saltosin", chapter: first, page: 12)
        let chapterId = id(manga, first)
        for page in [30, 31, 32, 33] {
            reader.setCurrentPage(page, position: nil)
        }
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(chapterId).completed == false, "completed after a jump from page 12 to 30")
        #expect(refusals(chapterId).contains("webtoon: no completa, salto 12→30"), "\(refusals(chapterId))")
        // asking again does not repeat the line
        reader.setCurrentPage(32, position: nil)
        reader.setCurrentPage(33, position: nil)
        try await Task.sleep(for: .seconds(1))
        #expect(refusals(chapterId).filter { $0 == "webtoon: no completa, salto 12→30" }.count == 1)
        await closeWebtoon(manga)
    }

    /// The same jump, and on into the next chapter from the last page (the third way to complete): nothing either.
    @Test func aJumpDownAndOnToTheNextChapterDoesNotComplete() async throws {
        let (reader, manga) = try await openedWebtoon(mangaKey: "saltosiguiente", chapter: first, page: 12)
        for page in [30, 31, 32] {
            reader.setCurrentPage(page, position: nil)
        }
        reader.setChapter(second)
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(id(manga, first)).completed == false, "completed going on to the next chapter after a jump")
        await closeWebtoon(manga)
    }

    /// Protector (born green): from the first page down to the transition, page after page: completed.
    @Test func goingDownFromTheFirstPageCompletes() async throws {
        let (reader, manga) = try await openedWebtoon(mangaKey: "bajarprimera", chapter: first, page: 1)
        for page in 2...(Self.webtoonPages + 1) {
            reader.setCurrentPage(page, position: nil)
        }
        #expect(await completed(id(manga, first)) == true)
        #expect(refusals(id(manga, first)).isEmpty)
        await closeWebtoon(manga)
    }

    /// The slider is deliberate: dropped at page 30, going down from there completes.
    @Test func theSliderToThe30thAndGoingDownCompletes() async throws {
        let (reader, manga) = try await openedWebtoon(mangaKey: "barra", chapter: first, page: 12)
        reader.sliderJump {
            reader.setCurrentPage(30, position: nil)
        }
        for page in [31, 32, 33] {
            reader.setCurrentPage(page, position: nil)
        }
        #expect(await completed(id(manga, first)) == true)
        await closeWebtoon(manga)
    }

    /// «Continuar» at page 12 (the stored one) and going down: completed.
    @Test func continuingAtThe12thAndGoingDownCompletes() async throws {
        let (reader, manga) = try await openedWebtoon(mangaKey: "continuar", chapter: first, page: 12)
        for page in 13...(Self.webtoonPages + 1) {
            reader.setCurrentPage(page, position: nil)
        }
        #expect(await completed(id(manga, first)) == true)
        await closeWebtoon(manga)
    }

    /// Entering the chapter going down from the previous one (scrolling on from its end) and reading it to the end:
    /// completed.
    @Test func enteringGoingDownFromThePreviousChapterAndReachingTheEndCompletes() async throws {
        let (reader, manga) = try await openedWebtoon(mangaKey: "entrando", chapter: first, page: 30)
        for page in [31, 32] {
            reader.setCurrentPage(page, position: nil)
        }
        reader.setChapter(second)
        for page in 1...(Self.webtoonPages + 1) {
            reader.setCurrentPage(page, position: nil)
        }
        #expect(await completed(id(manga, second)) == true)
        await closeWebtoon(manga)
    }
}
}
