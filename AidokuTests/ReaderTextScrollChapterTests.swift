//
//  ReaderTextScrollChapterTests.swift
//  AidokuTests
//
//  SUWA-17 C1: the scrolling text reader puts the previous chapter in above when the user goes up to the top, and
//  on the way tells the reader «previous chapter» and then «this chapter» again. That pair is not the user going
//  on to another chapter: nothing is completed by it, and never a chapter the user did not open. The text readers
//  keep the SUWA-12 rule (the end of the chapter reached with the app in front). Through the real
//  ReaderViewController and scrolling text reader.
//

import AidokuRunner
import Foundation
import Testing
import UIKit

@testable import Aidoku

@MainActor
@Suite(.serialized) struct ReaderTextScrollChapterTests {
    private let previous = AidokuRunner.Chapter(key: "t1", chapterNumber: 1)
    private let current = AidokuRunner.Chapter(key: "t2", chapterNumber: 2)

    @MainActor
    private struct Opened {
        let reader: ReaderViewController
        let text: ReaderTextViewController
        let window: UIWindow
        let ids: [ChapterIdentifier]

        var scrollView: UIScrollView? {
            text.view.subviews.compactMap { $0 as? UIScrollView }.first
        }

        func close() async {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: "Reader.textReaderStyle")
            for id in ids {
                await removeTestHistory(id)
            }
        }
    }

    private static func textPage(chapterKey: String, paragraphs: Int) -> Aidoku.Page {
        let text = (1...paragraphs).map { "Párrafo \($0) del capítulo \(chapterKey). " + String(repeating: "Texto de prueba. ", count: 30) }
            .joined(separator: "\n\n")
        return Aidoku.Page(sourceId: "lectortexto", chapterId: chapterKey, index: 0, text: text)
    }

    /// Opens chapter 2 (with chapter 1 before it) in the scrolling text reader; `paragraphs` long.
    private func open(mangaKey: String, paragraphs: Int) async throws -> Opened {
        let manga = AidokuRunner.Manga(sourceKey: "lectortexto", key: mangaKey, title: "Novela", chapters: [current, previous])
        let ids = [previous, current].map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key) }
        for id in ids {
            await removeTestHistory(id)
        }
        UserDefaults.standard.set("scroll", forKey: "Reader.textReaderStyle")
        let reader = ReaderViewController(source: nil, manga: manga, chapter: current)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        reader.presentedViewController?.dismiss(animated: false)
        reader.setReader(.text)
        let text = try #require(reader.reader as? ReaderTextViewController, "not the scrolling text reader")
        text.viewModel.preloadedChapter = current
        text.viewModel.preloadedPages = [Self.textPage(chapterKey: current.key, paragraphs: paragraphs)]
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(2))
        // what the reader gets when it asks for the previous chapter
        text.viewModel.preloadedChapter = previous
        text.viewModel.preloadedPages = [Self.textPage(chapterKey: previous.key, paragraphs: 40)]
        return Opened(reader: reader, text: text, window: window, ids: ids)
    }

    /// The user drags to `y` and lets go.
    private func userScrolls(_ opened: Opened, to y: CGFloat) throws {
        let scrollView = try #require(opened.scrollView)
        scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        opened.text.scrollViewDidEndDragging(scrollView, willDecelerate: false)
    }

    /// The completions the history wrote to the journal for a chapter.
    private func journaled(_ chapter: ChapterIdentifier) -> Int {
        CompletionJournal.lines().filter {
            let fields = $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return fields.count >= 5 && fields[1] == chapter.sourceKey && fields[2] == chapter.mangaKey
                && fields[3] == chapter.chapterKey && !fields[4].hasPrefix("webtoon:")
        }.count
    }

    /// Chapter 2 read to its end (completed, the SUWA-12 rule), then back up to the top: chapter 1 goes in above
    /// and is not completed.
    @Test func readToTheEndAndBackToTheTopDoesNotCompleteThePreviousChapter() async throws {
        let opened = try await open(mangaKey: "finyarriba", paragraphs: 40)
        let scrollView = try #require(opened.scrollView)
        try #require(opened.reader.pages.count > 1, "one virtual page only")
        let before = journaled(opened.ids[0])
        // to the end of chapter 2, step by step as one reads
        var y = scrollView.contentOffset.y
        while y < scrollView.contentSize.height - scrollView.bounds.height {
            y = min(y + 500, scrollView.contentSize.height - scrollView.bounds.height)
            try userScrolls(opened, to: y)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(opened.ids[1]).completed == true, "chapter 2 read to its end")
        // back up to the top: the previous chapter goes in above
        try userScrolls(opened, to: 0)
        try await Task.sleep(for: .seconds(3))
        #expect(await storedProgress(opened.ids[0]).completed == false, "chapter 1 completed without opening it")
        #expect(journaled(opened.ids[0]) - before == 0)
        await opened.close()
    }

    /// A chapter of a single virtual page (it fits on screen): opened and up to the top, chapter 1 goes in above
    /// and is not completed.
    @Test func aOnePageChapterAndUpToTheTopDoesNotCompleteThePreviousChapter() async throws {
        let opened = try await open(mangaKey: "unapagina", paragraphs: 1)
        #expect(opened.reader.pages.count == 1)
        let before = journaled(opened.ids[0])
        try userScrolls(opened, to: 0)
        try await Task.sleep(for: .seconds(3))
        #expect(await storedProgress(opened.ids[0]).completed == false, "chapter 1 completed without opening it")
        #expect(journaled(opened.ids[0]) - before == 0)
        await opened.close()
    }
}

// MARK: - SUWA-17 D4, D7: the previous chapter entered from below
extension ReaderTextScrollChapterTests {
    /// Chapter 2 opened and up to its top: chapter 1 goes in above and the screen is at its end (the transition after
    /// it: entered from below, not into its text). Back down into chapter 2: chapter 1 keeps what it had stored (it
    /// was not read), and the same leaving the reader at its end.
    @Test func intoThePreviousChapterFromBelowAndBackSavesNothingOfIt() async throws {
        let opened = try await open(mangaKey: "abajoyvuelta", paragraphs: 40)
        let scrollView = try #require(opened.scrollView)
        await DataRepositories.shared.history.savePage(PageSave(chapter: opened.ids[0], page: 3, totalPages: 9, scrollPosition: 0.3))
        try userScrolls(opened, to: 0)
        try await Task.sleep(for: .seconds(3))
        let top = scrollView.contentOffset.y
        try #require(top > scrollView.bounds.height, "chapter 1 did not go in above (y \(top))")
        try #require(opened.reader.chapter.key == previous.key, "not at the end of chapter 1 (y \(top))")
        // and back down into chapter 2
        try userScrolls(opened, to: top + scrollView.bounds.height * 1.5)
        try await Task.sleep(for: .seconds(3))
        #expect(opened.reader.chapter.key == current.key, "y \(scrollView.contentOffset.y), top \(top)")
        var record = await DataRepositories.shared.history.record(of: opened.ids[0])
        #expect(record?.progress == 3, "chapter 1 saved at page \(String(describing: record?.progress)) without reading it")
        #expect(record?.scrollPosition == 0.3)
        // up to its end again, and out of the reader there
        try userScrolls(opened, to: top)
        try await Task.sleep(for: .seconds(1))
        opened.reader.viewWillDisappear(false)
        try await Task.sleep(for: .seconds(1))
        record = await DataRepositories.shared.history.record(of: opened.ids[0])
        #expect(record?.progress == 3, "leaving: chapter 1 saved at page \(String(describing: record?.progress))")
        await opened.close()
    }
}

extension ReaderTextScrollChapterTests {
    /// The previous chapter entered from below, then up into its text: its page is saved as the reader tells it;
    /// then read down to its end: completed (the SUWA-12 rule).
    @Test func intoThePreviousChapterFromBelowThenReadItSavesAndCompletes() async throws {
        let opened = try await open(mangaKey: "abajoyleer", paragraphs: 40)
        let scrollView = try #require(opened.scrollView)
        try userScrolls(opened, to: 0)
        try await Task.sleep(for: .seconds(3))
        let top = scrollView.contentOffset.y
        try #require(top > scrollView.bounds.height * 3, "chapter 1 did not go in above (y \(top))")
        // up into the end of chapter 1, then well into its text
        try userScrolls(opened, to: top - scrollView.bounds.height * 0.7)
        try await Task.sleep(for: .seconds(1))
        try userScrolls(opened, to: top - scrollView.bounds.height * 3)
        try await Task.sleep(for: .seconds(3))
        try #require(opened.reader.chapter.key == previous.key)
        let page = opened.reader.currentPage
        let record = await DataRepositories.shared.history.record(of: opened.ids[0])
        #expect(page >= 1)
        #expect(record?.progress == page, "chapter 1 at page \(page), saved \(String(describing: record?.progress))")
        #expect(await storedProgress(opened.ids[0]).completed == false)
        // read down to its end
        var y = scrollView.contentOffset.y
        while y < top - 60 {
            y = min(y + 300, top - 60)
            try userScrolls(opened, to: y)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(2))
        #expect(await storedProgress(opened.ids[0]).completed == true, "chapter 1 read to its end")
        await opened.close()
    }
}
