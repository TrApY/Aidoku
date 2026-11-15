//
//  ReaderForegroundTests.swift
//  AidokuTests
//
//  SUWA-12 I1: with the app out of front, the reader ignores every page change (no page, no save, nothing
//  «seen», no completion), through the real ReaderViewController; the text reader's completion too.
//

import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit

@testable import Aidoku

@MainActor
func makeTestReader(mangaKey: String, center: NotificationCenter) -> (ReaderViewController, ChapterIdentifier) {
    let manga = AidokuRunner.Manga(sourceKey: "lectordelante", key: mangaKey, title: "Delante")
    let chapter = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
    let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
    reader.appActivity = ReaderAppActivity(center: center, active: true)
    reader.setPages((0..<38).map {
        Page(sourceId: manga.sourceKey, chapterId: chapter.key, index: $0, imageURL: "https://example.invalid/\($0).jpg")
    })
    return (reader, ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key))
}

func storedProgress(_ chapterId: ChapterIdentifier) async -> (completed: Bool, progress: Int?) {
    await CoreDataManager.shared.container.performBackgroundTask { context in
        CoreDataManager.shared.getProgress(chapterId: chapterId, context: context)
    }
}

func removeTestHistory(_ chapterId: ChapterIdentifier) async {
    await CoreDataManager.shared.container.performBackgroundTask { context in
        CoreDataManager.shared.removeHistory(mangaId: chapterId.mangaIdentifier, context: context)
        try? context.save()
    }
}

@MainActor
@Suite(.serialized) struct ReaderForegroundTests {
    /// The iPad at 14:18: page 18, the app goes to the background and the webtoon reports the end transition.
    @Test func aPageChangeInTheBackgroundIsIgnored() async throws {
        let center = NotificationCenter()
        let (reader, chapterId) = makeTestReader(mangaKey: "fondo", center: center)
        await removeTestHistory(chapterId)
        defer { Task { await removeTestHistory(chapterId) } }

        reader.setCurrentPage(18, position: nil)
        try await Task.sleep(for: .seconds(3))
        #expect(await storedProgress(chapterId).progress == 18) // saved by the reader, as always

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        reader.setCurrentPage(39, position: nil)
        #expect(reader.currentPage == 18)
        try await Task.sleep(for: .seconds(3))
        let stored = await storedProgress(chapterId)
        #expect(stored.progress == 18)
        #expect(stored.completed == false)

        // back in front, the transition first: the last page wasn't seen in front
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        reader.setCurrentPage(39, position: nil)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(chapterId).completed == false)
    }

    @Test func whileResigningActiveNothingCountsEither() async throws {
        let center = NotificationCenter()
        let (reader, chapterId) = makeTestReader(mangaKey: "inactiva", center: center)
        await removeTestHistory(chapterId)
        defer { Task { await removeTestHistory(chapterId) } }
        reader.setCurrentPage(10, position: nil)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        reader.setCurrentPage(25, position: nil)
        #expect(reader.currentPage == 10)
    }

    /// The text reader calls setCompleted itself at the end of a section.
    @Test func aCompletionWithTheAppOutOfFrontDoesNotCount() async throws {
        let center = NotificationCenter()
        let (reader, chapterId) = makeTestReader(mangaKey: "texto", center: center)
        await removeTestHistory(chapterId)
        defer { Task { await removeTestHistory(chapterId) } }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(reader.setCompleted() == false)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(chapterId).completed == false)
    }
}
