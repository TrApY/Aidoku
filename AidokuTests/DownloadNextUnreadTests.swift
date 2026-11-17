//
//  DownloadNextUnreadTests.swift
//  AidokuTests
//
//  SUWA-18 D1: «Descargar › Siguientes N sin leer» (upstream #1124) counts the same chapters as «descarga
//  adelantada»: the next N after the last read one, with the series' chapter filters, and the ones already
//  downloaded or queued (by either of them) count, so neither queues a chapter twice.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct DownloadNextUnreadTests {
    private static let sourceKey = "nextunreadtest"

    /// Chapters 1...8 newest first (as sources give them).
    private static func newestFirst(language: (Int) -> String? = { _ in nil }) -> [AidokuRunner.Chapter] {
        var chapters: [AidokuRunner.Chapter] = []
        for number in (1...8).reversed() {
            let chapter = AidokuRunner.Chapter(key: "c\(number)", chapterNumber: Float(number), language: language(number))
            chapters.append(chapter)
        }
        return chapters
    }

    /// A library manga of a fake source with `chapters`, the ones in `completed` read, and its own download
    /// manager (queue not saved) paused by the user, so nothing really downloads. Cleans everything up afterwards.
    private func withLibraryManga(
        key: String,
        chapters: [AidokuRunner.Chapter] = Self.newestFirst(),
        completed: [Int] = [],
        languageFilter: String? = nil,
        _ body: (AidokuRunner.Manga, DownloadManager) async throws -> Void
    ) async throws {
        let manga = AidokuRunner.Manga(sourceKey: Self.sourceKey, key: key, title: "Siguientes \(key)")
        let ids = chapters.map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key) }
        let manager = DownloadManager(queueStateKey: nil)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: chapters)
        let read = completed.map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c\($0)") }
        if !read.isEmpty {
            await DataRepositories.shared.history.markCompleted(read, date: .now)
        }
        if let languageFilter {
            await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getManga(mangaId: manga.identifier, context: context)?.langFilter = languageFilter
                try? context.save()
            }
        }
        await manager.pauseDownloads(byUser: true)
        do {
            try await body(manga, manager)
        } catch {
            Issue.record(error)
        }
        await manager.cancelDownloads(for: ids)
        await DataRepositories.shared.history.remove(chapters: ids)
        DownloadAheadSetting.set(0, for: manga.identifier)
        await MangaManager.shared.removeFromLibrary(mangaId: manga.identifier)
        DownloadManager.directory.appendingPathComponent(manga.sourceKey).appendingPathComponent(manga.key).removeItem()
    }

    /// The manga's chapters in the manager's queue, in queue order.
    private func queued(_ manager: DownloadManager, _ manga: AidokuRunner.Manga) async -> [String] {
        await manager.getDownloadQueue()[manga.sourceKey]?
            .filter { $0.chapterIdentifier.mangaKey == manga.key }
            .map(\.chapterIdentifier.chapterKey) ?? []
    }

    /// c3 was skipped without reading it: the next two are c5 and c6, as for «descarga adelantada».
    @Test func theNextUnreadStartAfterTheLastReadChapter() async throws {
        try await withLibraryManga(key: "1", completed: [1, 2, 4]) { manga, manager in
            await manager.downloadUnread(manga: manga, limit: 2, start: .unlessUserPaused)
            #expect(await queued(manager, manga) == ["c5", "c6"])
        }
    }

    /// «Descarga adelantada» of 2 queued c1 and c2: «next 3 unread» adds only c3, and «descarga adelantada» of 3
    /// then has nothing left to queue.
    @Test func nextUnreadAndDownloadAheadCountTheSameChapters() async throws {
        try await withLibraryManga(key: "2") { manga, manager in
            DownloadAheadSetting.set(2, for: manga.identifier)
            let ahead = await manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false)
            #expect(ahead.map(\.key) == ["c1", "c2"])
            await manager.downloadUnread(manga: manga, limit: 3, start: .unlessUserPaused)
            #expect(await queued(manager, manga) == ["c1", "c2", "c3"])
            DownloadAheadSetting.set(3, for: manga.identifier)
            #expect(await manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false).isEmpty)
        }
    }

    /// The series shows only Spanish chapters: the next two unread are the next two Spanish ones.
    @Test func theSeriesChapterFiltersAreApplied() async throws {
        let chapters = Self.newestFirst { $0 % 2 == 0 ? "es" : "en" }
        try await withLibraryManga(key: "3", chapters: chapters, languageFilter: "es") { manga, manager in
            await manager.downloadUnread(manga: manga, limit: 2, start: .unlessUserPaused)
            #expect(await queued(manager, manga) == ["c2", "c4"])
        }
    }

    /// The series page passes its own chapters (a series not in the library has none stored): they are used.
    @Test func theSeriesPagesChaptersAreUsed() async throws {
        let manga = AidokuRunner.Manga(
            sourceKey: Self.sourceKey, key: "fuera", title: "Fuera de la biblioteca", chapters: Self.newestFirst()
        )
        let manager = DownloadManager(queueStateKey: nil)
        await manager.pauseDownloads(byUser: true)
        await manager.downloadUnread(manga: manga, limit: 2, start: .unlessUserPaused)
        #expect(await queued(manager, manga) == ["c1", "c2"])
        await manager.cancelDownloads(for: Self.newestFirst().map {
            ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
        })
        DownloadManager.directory.appendingPathComponent(manga.sourceKey).appendingPathComponent(manga.key).removeItem()
    }

    /// «Sin leer» without a limit still queues every unread chapter, oldest first.
    @Test func allUnreadStillQueuesEveryUnreadChapter() async throws {
        try await withLibraryManga(key: "4", completed: [1, 2, 4]) { manga, manager in
            await manager.downloadUnread(manga: manga, start: .unlessUserPaused)
            #expect(await queued(manager, manga) == ["c3", "c5", "c6", "c7", "c8"])
        }
    }
}
