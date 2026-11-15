//
//  HistoryContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L4: the reads of HistoryRepository and ChapterRepository (and the history reads of MainActorReads),
//  against every fixture (each test on a store of its own). They fix what the app does today (spec §1.5 nº 1, 4-6).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct HistoryContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    /// the same manga key under another source is another manga
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")

    private func id(_ key: String, _ manga: MangaIdentifier? = nil) -> ChapterIdentifier {
        let manga = manga ?? self.manga
        return ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    private func chapter(_ key: String, _ number: Float?, volume: Float? = nil) -> AidokuRunner.Chapter {
        AidokuRunner.Chapter(key: key, chapterNumber: number, volumeNumber: volume)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    @Test(arguments: repositoryFixtures)
    func anEmptyStoreHasNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        #expect(await history.progress(of: id("c1")) == ChapterProgress(completed: false, progress: nil))
        #expect(await history.record(of: id("c1")) == nil)
        #expect(await history.readingHistory(of: manga).isEmpty)
        #expect(await history.recent(limit: 10, offset: 0).isEmpty)
        #expect(await !history.hasHistory(of: manga))
        #expect(await history.earliestReadDate(of: manga) == nil)
        #expect(await history.highestReadNumber(of: manga, mode: .default) == nil)
        #expect(await store.repos.chapters.chapters(of: manga).isEmpty)
        #expect(await store.repos.chapters.chapter(id("c1")) == nil)
        await store.tearDown()
    }

    /// nil = no history; -1 = history without a page (as a session or marking it read leaves it).
    @Test(arguments: repositoryFixtures)
    func progressTellsNoHistoryFromNoPage(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1")))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 7))
        await store.seed.addHistory(HistorySeed(chapter: id("c3"), progress: 4, completed: true))
        #expect(await history.progress(of: id("c1")) == ChapterProgress(completed: false, progress: -1))
        #expect(await history.progress(of: id("c2")) == ChapterProgress(completed: false, progress: 7))
        #expect(await history.progress(of: id("c3")) == ChapterProgress(completed: true, progress: 4))
        #expect(await history.progress(of: id("c1", sameKeyOtherSource)) == ChapterProgress(completed: false, progress: nil))
        #expect(await history.progress(of: id("c9")) == ChapterProgress(completed: false, progress: nil))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func aRecordCarriesEveryField(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1")))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 12, total: 38, dateRead: date(812_345_678.5), scrollPosition: 0.0))
        await store.seed.addHistory(HistorySeed(chapter: id("c3"), progress: Int(Int16.max), total: Int(Int16.max), completed: true, dateRead: nil, scrollPosition: -1.5))
        #expect(await history.record(of: id("c1")) == HistoryRecord(chapterId: id("c1"), progress: -1, total: 0, completed: false, dateRead: .distantPast, scrollPosition: nil))
        #expect(await history.record(of: id("c2")) == HistoryRecord(chapterId: id("c2"), progress: 12, total: 38, completed: false, dateRead: date(812_345_678.5), scrollPosition: 0.0))
        #expect(await history.record(of: id("c3")) == HistoryRecord(chapterId: id("c3"), progress: 32767, total: 32767, completed: true, dateRead: nil, scrollPosition: -1.5))
        #expect(await history.record(of: id("c2", sameKeyOtherSource)) == nil)
        await store.tearDown()
    }

    /// page -1 if completed (else the page, -1 included); date in whole seconds since 1970, -1 without date.
    @Test(arguments: repositoryFixtures)
    func theReadingHistoryGivesPageAndDate(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 5, dateRead: Date(timeIntervalSince1970: 1000.9)))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 9, completed: true, dateRead: Date(timeIntervalSince1970: 2000)))
        await store.seed.addHistory(HistorySeed(chapter: id("c3"), progress: 3, dateRead: nil))
        await store.seed.addHistory(HistorySeed(chapter: id("c4")))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", sameKeyOtherSource), progress: 1))
        #expect(await history.readingHistory(of: manga) == [
            "c1": ReadingHistoryEntry(page: 5, date: 1000),
            "c2": ReadingHistoryEntry(page: -1, date: 2000),
            "c3": ReadingHistoryEntry(page: 3, date: -1),
            "c4": ReadingHistoryEntry(page: -1, date: Int(Date.distantPast.timeIntervalSince1970))
        ])
        #expect(await history.readingHistory(of: sameKeyOtherSource) == ["c1": ReadingHistoryEntry(page: 1, date: Int(Date.distantPast.timeIntervalSince1970))])
        await store.tearDown()
    }

    /// It writes (§1.5 nº 4): repeated rows of a chapter are removed, one is kept.
    @Test(arguments: repositoryFixtures)
    func theReadingHistoryRemovesRepeatedRows(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 3))
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 8))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 1))
        #expect(await store.seed.historyRows(of: id("c1")) == 2)
        let first = await history.readingHistory(of: manga)
        #expect(first.count == 2)
        #expect([3, 8].contains(first["c1"]?.page ?? 0))
        #expect(await store.seed.historyRows(of: id("c1")) == 1)
        #expect(await history.readingHistory(of: manga) == first)
        await store.tearDown()
    }

    /// It writes (§1.5 nº 4): a row without chapter is linked to it, only if the manga is in the library.
    @Test(arguments: repositoryFixtures)
    func theReadingHistoryLinksChaptersOnlyInTheLibrary(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        let outside = MangaIdentifier(sourceKey: "contract.source", mangaKey: "fuera")
        await store.addToLibrary([manga])
        await store.seed.addChapters([chapter("c1", 1), chapter("c2", 2)], to: manga)
        await store.seed.addChapters([chapter("c1", 1)], to: outside)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 2, linked: false))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", outside), progress: 2, linked: false))
        #expect(await !store.seed.isLinked(id("c1")))
        _ = await history.readingHistory(of: manga)
        _ = await history.readingHistory(of: outside)
        #expect(await store.seed.isLinked(id("c1")))
        #expect(await !store.seed.isLinked(id("c1", outside)))
        await store.tearDown()
    }

    /// Newest first; the same date: highest chapter number first (§1.5 nº 6); limit and offset.
    @Test(arguments: repositoryFixtures)
    func recentIsNewestFirstThenHighestChapter(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.addToLibrary([manga])
        await store.seed.addChapters([chapter("c3", 3), chapter("c2", 2), chapter("c1", 1)], to: manga)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 1, dateRead: date(200)))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 1, dateRead: date(100)))
        await store.seed.addHistory(HistorySeed(chapter: id("c3"), progress: 1, dateRead: date(200)))
        await store.seed.addHistory(HistorySeed(chapter: id("x", sameKeyOtherSource), progress: 1, dateRead: date(150)))
        #expect(await history.recent(limit: 10, offset: 0).map(\.chapterId) == [id("c3"), id("c1"), id("x", sameKeyOtherSource), id("c2")])
        #expect(await history.recent(limit: 1, offset: 1).map(\.chapterId) == [id("c1")])
        #expect(await history.recent(limit: 10, offset: 4).isEmpty)
        #expect(await history.recent(limit: 1, offset: 0).first == HistoryRecord(chapterId: id("c3"), progress: 1, total: 0, completed: false, dateRead: date(200), scrollPosition: nil))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func hasHistoryIsPerManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1")))
        #expect(await history.hasHistory(of: manga))
        #expect(await !history.hasHistory(of: sameKeyOtherSource))
        await store.tearDown()
    }

    /// Only completed chapters count.
    @Test(arguments: repositoryFixtures)
    func theEarliestReadDateCountsOnlyCompleted(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), completed: true, dateRead: date(300)))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), completed: true, dateRead: date(100)))
        await store.seed.addHistory(HistorySeed(chapter: id("c3"), progress: 4, dateRead: date(50)))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", sameKeyOtherSource), progress: 4, dateRead: date(10)))
        #expect(await history.earliestReadDate(of: manga) == date(100))
        #expect(await history.earliestReadDate(of: sameKeyOtherSource) == nil)
        await store.tearDown()
    }

    /// The highest number among completed (linked) chapters, as the mode the caller gives counts it: default the
    /// chapter number; chapter mode falls back to the volume when the chapter is not > 0; volume mode the volume,
    /// falling back to the chapter.
    @Test(arguments: repositoryFixtures)
    func theHighestReadNumberFollowsTheMode(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        let volumes = MangaIdentifier(sourceKey: "contract.source", mangaKey: "volumes")
        let noVolume = MangaIdentifier(sourceKey: "contract.source", mangaKey: "sin-volumen")
        let unlinked = MangaIdentifier(sourceKey: "contract.source", mangaKey: "sin-enlace")
        await store.addToLibrary([manga, volumes, noVolume, unlinked])
        await store.seed.addChapters([chapter("c3", 10, volume: 2), chapter("c2", 2, volume: 1), chapter("c1", 1, volume: 1)], to: manga)
        await store.seed.addChapters([chapter("c1", 0, volume: 3)], to: volumes)
        await store.seed.addChapters([chapter("c1", 5)], to: noVolume)
        await store.seed.addChapters([chapter("c1", 7, volume: 7)], to: unlinked)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), completed: true))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), completed: true))
        await store.seed.addHistory(HistorySeed(chapter: id("c3"), progress: 4))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", volumes), completed: true))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", noVolume), completed: true))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", unlinked), completed: true, linked: false))
        #expect(await history.highestReadNumber(of: manga, mode: .default) == 2)
        #expect(await history.highestReadNumber(of: manga, mode: .chapter) == 2)
        #expect(await history.highestReadNumber(of: manga, mode: .volume) == 1)
        #expect(await history.highestReadNumber(of: volumes, mode: .default) == 0)
        #expect(await history.highestReadNumber(of: volumes, mode: .chapter) == 3)
        #expect(await history.highestReadNumber(of: volumes, mode: .volume) == 3)
        #expect(await history.highestReadNumber(of: noVolume, mode: .volume) == 5)
        for mode in ChapterTitleDisplayMode.allCases {
            #expect(await history.highestReadNumber(of: unlinked, mode: mode) == nil, "\(mode)")
        }
        await store.tearDown()
    }

    /// Stored chapters in source order, with what they carry; the same keys under another source are apart.
    @Test(arguments: repositoryFixtures)
    func storedChaptersComeInSourceOrder(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let chapters = store.repos.chapters
        await store.addToLibrary([manga])
        let full = AidokuRunner.Chapter(
            key: "c2", title: "ñ漢字🙂", chapterNumber: 2.5, volumeNumber: 1, dateUploaded: date(1000),
            scanlators: ["a", "b"], url: URL(string: "https://example.test/c2"), language: "es", thumbnail: "t", locked: true
        )
        await store.seed.addChapters([chapter("c3", nil), full, chapter("c1", 1)], to: manga)
        let stored = await chapters.chapters(of: manga)
        #expect(stored.map(\.key) == ["c3", "c2", "c1"])
        let c2 = try #require(await chapters.chapter(id("c2")))
        #expect(c2.title == "ñ漢字🙂")
        #expect(c2.chapterNumber == 2.5)
        #expect(c2.volumeNumber == 1)
        #expect(c2.dateUploaded == date(1000))
        #expect(c2.scanlators == ["a", "b"])
        #expect(c2.url == URL(string: "https://example.test/c2"))
        #expect(c2.language == "es")
        #expect(c2.thumbnail == "t")
        #expect(c2.locked)
        #expect(stored[1].title == c2.title && stored[1].scanlators == c2.scanlators)
        #expect(await chapters.chapter(id("c3"))?.chapterNumber == nil)
        #expect(await chapters.chapters(of: sameKeyOtherSource).isEmpty)
        #expect(await chapters.chapter(id("c1", sameKeyOtherSource)) == nil)
        await store.tearDown()
    }

    /// The reader reads synchronously on the main thread the same as the async reads.
    @Test(arguments: repositoryFixtures)
    func theMainThreadReadsSeeTheSame(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 6, total: 20, scrollPosition: 0.25))
        let reads = store.repos.mainActorReads
        let c1 = id("c1")
        let c2 = id("c2")
        let (progress, record, none) = await MainActor.run { (reads.progress(of: c1), reads.record(of: c1), reads.progress(of: c2)) }
        #expect(progress == ChapterProgress(completed: false, progress: 6))
        #expect(record?.scrollPosition == 0.25)
        #expect(record == (await store.repos.history.record(of: c1)))
        #expect(none == ChapterProgress(completed: false, progress: nil))
        await store.tearDown()
    }
}
