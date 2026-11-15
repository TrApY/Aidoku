//
//  ProgressWithoutServerDateTests.swift
//  AidokuTests
//
//  SUWA-12 F: a chapter the server has «read» without a date (lastReadAt 0, marked with
//  updateChapters(isRead:)) never turns a chapter half read here into read.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

private final class DatelessTracker: PageTracker, @unchecked Sendable {
    struct Unsupported: Error {}
    let id = "test.datelesstracker"
    let name = "Sin fecha"
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

@Suite(.serialized) struct ProgressWithoutServerDateTests {
    @Test func aChapterMarkedReadWithoutADateHasNoDate() {
        #expect(SuwayomiApi.readDate(lastReadAt: "0") == nil)
        #expect(SuwayomiApi.readDate(lastReadAt: "") == nil)
        #expect(SuwayomiApi.readDate(lastReadAt: "1794737210") == Date(timeIntervalSince1970: 1_794_737_210))
        #expect(SuwayomiApi.readDate(lastReadAt: "1794737210000") == Date(timeIntervalSince1970: 1_794_737_210))
    }

    /// What JoTa saw: chapter 1 half read here, the server says «read» with no date → still half read
    /// (and «Continuar» opens chapter 1); a chapter with no history here still takes the server's «read».
    @Test func aChapterHalfReadHereStaysHalfRead() async throws {
        let manga = AidokuRunner.Manga(sourceKey: "syncsinfecha", key: "m1", title: "Sin fecha")
        let chapters: [AidokuRunner.Chapter] = [.init(key: "c2", chapterNumber: 2), .init(key: "c1", chapterNumber: 1)]
        let c1 = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1")
        let c2 = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c2")
        let tracker = DatelessTracker(progress: [
            "c1": .init(completed: true, page: 38, date: nil),
            "c2": .init(completed: true, page: 30, date: nil)
        ])
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.setProgress(12, chapterId: c1, totalPages: 38, dateRead: Date(), completed: false, context: context)
            try? context.save()
        }
        await DataRepositories.shared.tracks.add(TrackItem(id: "sinfecha-m1", trackerId: tracker.id, mangaId: manga.identifier, title: nil, chapterOffset: 0))
        await TrackerManager.shared.syncPageTrackerHistory(
            manga: manga,
            chapters: chapters,
            trackerLookup: { $0 == tracker.id ? tracker : nil },
            downloadAhead: { _ in }
        )
        let (first, second) = await CoreDataManager.shared.container.performBackgroundTask { context in
            let first = CoreDataManager.shared.getProgress(chapterId: c1, context: context)
            let second = CoreDataManager.shared.getProgress(chapterId: c2, context: context)
            CoreDataManager.shared.removeHistory(mangaId: manga.identifier, context: context)
            try? context.save()
            return (first, second)
        }
        await DataRepositories.shared.tracks.remove(trackerId: tracker.id, manga: manga.identifier)
        #expect(first.0 == false) // still half read
        #expect(first.1 == 12)
        #expect(second.0 == true) // no history here: created from the server
    }
}
