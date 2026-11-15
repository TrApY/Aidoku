//
//  TrackerReadDateTests.swift
//  AidokuTests
//
//  SUWA-12 H4: a chapter the server has «read» without a date and with no history here gets its history,
//  but the manga isn't «read recently» because of it. H3: those completions go in the journal.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

private final class NoDateTracker: PageTracker, @unchecked Sendable {
    struct Unsupported: Error {}
    let id = "test.nodatetracker"
    let name = "Sin fecha H"
    let icon: PlatformImage? = nil
    let isLoggedIn = true
    let progress: [String: ChapterReadProgress]

    init(progress: [String: ChapterReadProgress]) {
        self.progress = progress
    }

    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws {}
    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress] {
        progress
    }
    func getTrackerInfo() async throws -> TrackerInfo { throw Unsupported() }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { throw Unsupported() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}

@Suite(.serialized) struct TrackerReadDateTests {
    private let lastWeek = Date(timeIntervalSince1970: 1_794_000_000)

    /// Sync the chapter `c1` read without a date into a library manga last read a week ago.
    private func sync(mangaKey: String) async throws -> (lastRead: Date?, completed: Bool) {
        let manga = AidokuRunner.Manga(sourceKey: "syncsinfechah", key: mangaKey, title: "Sin fecha")
        let chapters: [AidokuRunner.Chapter] = [.init(key: "c1", chapterNumber: 1)]
        let c1 = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1")
        let tracker = NoDateTracker(progress: ["c1": .init(completed: true, page: 0, date: nil)])
        let lastWeek = lastWeek
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(manga: manga, chapters: chapters, context: context)
            CoreDataManager.shared.setRead(mangaId: manga.identifier, date: lastWeek, context: context)
            _ = CoreDataManager.shared.createTrack(id: "sinfechah-\(mangaKey)", trackerId: tracker.id, mangaId: manga.identifier, title: nil, context: context)
            try? context.save()
        }
        await TrackerManager.shared.syncPageTrackerHistory(
            manga: manga,
            chapters: chapters,
            trackerLookup: { $0 == tracker.id ? tracker : nil },
            downloadAhead: { _ in }
        )
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            let lastRead = CoreDataManager.shared.getLibraryManga(mangaId: manga.identifier, context: context)?.lastRead
            let completed = CoreDataManager.shared.getProgress(chapterId: c1, context: context).0
            CoreDataManager.shared.removeHistory(mangaId: manga.identifier, context: context)
            CoreDataManager.shared.removeTrack(trackerId: tracker.id, mangaId: manga.identifier, context: context)
            CoreDataManager.shared.removeManga(mangaId: manga.identifier, context: context)
            try? context.save()
            return (lastRead, completed)
        }
    }

    @Test func aReadWithoutDateDoesNotMakeTheMangaReadRecently() async throws {
        let result = try await sync(mangaKey: "m1")
        #expect(result.completed) // the history is created
        #expect(result.lastRead == lastWeek) // and the manga keeps its read date
    }

    @Test func aCompletionFromTheServerGoesInTheJournal() async throws {
        let before = CompletionJournal.lines().filter { $0.contains("syncsinfechah\tm2\tc1") }.count
        _ = try await sync(mangaKey: "m2")
        let lines = CompletionJournal.lines().filter { $0.contains("syncsinfechah\tm2\tc1") }
        #expect(lines.count == before + 1)
        #expect(lines.last?.contains("sincronización test.nodatetracker") == true)
    }
}
