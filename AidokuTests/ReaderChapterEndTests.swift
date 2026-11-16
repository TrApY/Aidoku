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

@MainActor
@Suite(.serialized) struct ReaderChapterEndTests {
    private static let pageCount = 38
    private let first = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
    private let second = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)

    /// A reader on `chapter` of a manga with chapters 1 and 2 (the source's order, newest first).
    private func reader(mangaKey: String, chapter: AidokuRunner.Chapter) async -> (ReaderViewController, AidokuRunner.Manga) {
        let manga = AidokuRunner.Manga(sourceKey: "lectorfinal", key: mangaKey, title: "Final", chapters: [second, first])
        await DataRepositories.shared.history.removeAll(of: manga.identifier)
        let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        // set up as when it opens (loading its view starts a reading session), then the chapter's pages
        reader.loadViewIfNeeded()
        try? await Task.sleep(for: .seconds(1))
        reader.presentedViewController?.dismiss(animated: false)
        reader.setPages((0..<Self.pageCount).map {
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
}
