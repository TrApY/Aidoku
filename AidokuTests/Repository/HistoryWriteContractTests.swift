//
//  HistoryWriteContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L5: the writes of HistoryRepository and ReadingSessionRepository, against every fixture (each test
//  on a store of its own): the page save of SUWA-7 and the completion of SUWA-12 (spec §1.3 nº 1-3, §1.5 nº 1-3),
//  and that a failed save leaves nothing half done.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct HistoryWriteContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    /// the same manga key under another source is another manga
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")
    /// not in the library
    private let outside = MangaIdentifier(sourceKey: "contract.source", mangaKey: "fuera")

    private func id(_ key: String, _ manga: MangaIdentifier? = nil) -> ChapterIdentifier {
        let manga = manga ?? self.manga
        return ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    /// within a minute of now: the dates seeded are from 2001, and under the whole suite's load the first write
    /// of a fresh Core Data store has taken 6 and 11 s (SUWA-17 H)
    private func isNow(_ date: Date?) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSinceNow) < 60
    }

    // MARK: - savePage (SUWA-7)

    @Test(arguments: repositoryFixtures)
    func aPageCreatesTheHistoryAndMovesLastRead(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.addToLibrary([manga])
        await store.seed.setLastRead(date(-1000), of: manga)
        #expect(await history.savePage(PageSave(chapter: id("c1"), page: 3, totalPages: 38, scrollPosition: 0.25)))
        let record = try #require(await history.record(of: id("c1")))
        #expect(record.progress == 3)
        #expect(record.total == 38)
        #expect(record.scrollPosition == 0.25)
        #expect(!record.completed)
        #expect(isNow(record.dateRead))
        #expect(isNow(await store.seed.lastRead(of: manga)))
        #expect(await history.progress(of: id("c1")) == ChapterProgress(completed: false, progress: 3))
        // only that chapter, only that manga
        #expect(await history.record(of: id("c1", sameKeyOtherSource)) == nil)
        #expect(await history.record(of: id("c2")) == nil)
        await store.tearDown()
    }

    /// Outside the library the page is saved all the same (there is no last read date to move).
    @Test(arguments: repositoryFixtures)
    func aPageOutsideTheLibraryIsSaved(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        #expect(await history.savePage(PageSave(chapter: id("c1", outside), page: 5)))
        #expect(await history.progress(of: id("c1", outside)) == ChapterProgress(completed: false, progress: 5))
        #expect(await store.seed.lastRead(of: outside) == nil)
        await store.tearDown()
    }

    /// nil total or scroll position keep what was stored; the page and the date always change.
    @Test(arguments: repositoryFixtures)
    func aPageKeepsTotalAndPositionWhenNotGiven(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 2, total: 38, dateRead: date(100), scrollPosition: 0.0))
        #expect(await history.savePage(PageSave(chapter: id("c1"), page: 9)))
        let record = try #require(await history.record(of: id("c1")))
        #expect(record.progress == 9)
        #expect(record.total == 38)
        #expect(record.scrollPosition == 0.0)
        #expect(isNow(record.dateRead))
        #expect(await store.seed.historyRows(of: id("c1")) == 1)
        // given: they change (also to 0)
        #expect(await history.savePage(PageSave(chapter: id("c1"), page: 10, totalPages: 0, scrollPosition: -1.5)))
        #expect(await history.record(of: id("c1"))?.total == 0)
        #expect(await history.record(of: id("c1"))?.scrollPosition == -1.5)
        await store.tearDown()
    }

    /// Saving a page never un-completes (§1.5 nº 2).
    @Test(arguments: repositoryFixtures)
    func aPageNeverUncompletes(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 38, total: 38, completed: true, dateRead: date(100)))
        #expect(await history.savePage(PageSave(chapter: id("c1"), page: 4)))
        let record = try #require(await history.record(of: id("c1")))
        #expect(record.completed)
        #expect(record.progress == 4)
        #expect(await history.progress(of: id("c1")) == ChapterProgress(completed: true, progress: 4))
        await store.tearDown()
    }

    // MARK: - markCompleted (SUWA-12)

    /// nil: did not save; false: nothing new; true: saved (§2.4). Only the new ones change, with read date `date`.
    @Test(arguments: repositoryFixtures)
    func completingIgnoresWhatIsAlreadyCompleted(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.addToLibrary([manga])
        await store.seed.setLastRead(date(-1000), of: manga)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 38, completed: true, dateRead: date(100)))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 7, total: 38, dateRead: date(200), scrollPosition: 0.5))
        #expect(await history.markCompleted([], date: date(300)) == false)
        #expect(await history.markCompleted([id("c1")], date: date(300)) == false)
        #expect(await store.seed.lastRead(of: manga) == date(-1000)) // nothing new: nothing saved
        #expect(await history.record(of: id("c1"))?.dateRead == date(100))

        #expect(await history.markCompleted([id("c1"), id("c2"), id("c3")], date: date(400)) == true)
        #expect(await history.record(of: id("c1"))?.dateRead == date(100)) // already completed: untouched
        let c2 = try #require(await history.record(of: id("c2")))
        // completing leaves it at its last page (SUWA-17 D2: a page before the last one is a reread)
        #expect(c2.completed && c2.dateRead == date(400) && c2.progress == 38 && c2.total == 38 && c2.scrollPosition == 0.5)
        // a chapter without history: a new row, -1 page (§1.5 nº 1)
        #expect(await history.record(of: id("c3")) == HistoryRecord(chapterId: id("c3"), progress: -1, total: 0, completed: true, dateRead: date(400), scrollPosition: nil))
        #expect(await store.seed.lastRead(of: manga) == date(400))
        #expect(await history.markCompleted([id("c2"), id("c3")], date: date(500)) == false)
        #expect(await store.seed.lastRead(of: manga) == date(400))
        #expect(await history.record(of: id("c1", sameKeyOtherSource)) == nil)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func completingOutsideTheLibraryIsSaved(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        #expect(await history.markCompleted([id("c1", outside)], date: date(10)) == true)
        #expect(await history.progress(of: id("c1", outside)) == ChapterProgress(completed: true, progress: -1))
        #expect(await store.seed.lastRead(of: outside) == nil)
        await store.tearDown()
    }

    // MARK: - removing

    @Test(arguments: repositoryFixtures)
    func removingTakesOnlyWhatIsAsked(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        for key in ["c1", "c2", "c3"] {
            await store.seed.addHistory(HistorySeed(chapter: id(key), progress: 1))
        }
        await store.seed.addHistory(HistorySeed(chapter: id("c1", sameKeyOtherSource), progress: 1))
        #expect(await history.remove(chapters: [id("c1"), id("c3"), id("nadie")]))
        #expect(await history.readingHistory(of: manga).keys.sorted() == ["c2"])
        #expect(await history.remove(chapters: []))
        #expect(await history.removeAll(of: manga))
        #expect(await history.readingHistory(of: manga).isEmpty)
        #expect(await history.hasHistory(of: sameKeyOtherSource))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func clearingKeepsTheLibraryOnlyIfAsked(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.addToLibrary([manga])
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 1))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", outside), progress: 1))
        await store.seed.addHistory(HistorySeed(chapter: id("c1", sameKeyOtherSource), progress: 1))
        #expect(await history.clear(excludingLibrary: true))
        #expect(await history.hasHistory(of: manga))
        #expect(await !history.hasHistory(of: outside))
        #expect(await !history.hasHistory(of: sameKeyOtherSource))
        #expect(await history.clear(excludingLibrary: false))
        #expect(await !history.hasHistory(of: manga))
        #expect(await history.recent(limit: 10, offset: 0).isEmpty)
        await store.tearDown()
    }

    // MARK: - sessions (apart from the page)

    @Test(arguments: repositoryFixtures)
    func aSessionIsItsOwnWrite(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sessions = store.repos.sessions
        let first = HistoryManager.ReadingSessionData(startDate: date(1000), endDate: date(1600.5), pagesRead: 12)
        // no history yet: one is made with read date = the session's end and no page
        #expect(await sessions.add(first, chapter: id("c1")))
        #expect(await store.repos.history.record(of: id("c1")) == HistoryRecord(chapterId: id("c1"), progress: -1, total: 0, completed: false, dateRead: date(1600.5), scrollPosition: nil))
        // with history: its read date and page stay
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 5, dateRead: date(50)))
        let second = HistoryManager.ReadingSessionData(startDate: date(2000), endDate: date(2100), pagesRead: Int(Int16.max))
        #expect(await sessions.add(second, chapter: id("c2")))
        #expect(await sessions.add(first, chapter: id("c2")))
        #expect(await store.repos.history.record(of: id("c2"))?.dateRead == date(50))
        #expect(await store.repos.history.record(of: id("c2"))?.progress == 5)
        let stored = await store.seed.sessions(of: id("c2"))
        #expect(stored.map(\.startDate) == [date(1000), date(2000)])
        #expect(stored.map(\.pagesRead) == [12, Int(Int16.max)])
        #expect(await store.seed.sessions(of: id("c1")).count == 1)
        await store.tearDown()
    }

    // MARK: - a failed save leaves nothing half done

    @Test(arguments: repositoryFixtures)
    func aFailedSaveLeavesNothingHalfDone(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        let failing = store.failingRepos
        await store.addToLibrary([manga])
        await store.seed.setLastRead(date(-1000), of: manga)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 2, total: 38, dateRead: date(100), scrollPosition: 0.5))

        #expect(await failing.history.markCompleted([id("c1"), id("c2")], date: date(500)) == nil)
        #expect(await store.seed.lastRead(of: manga) == date(-1000)) // lastRead not moved
        #expect(await history.progress(of: id("c1")) == ChapterProgress(completed: false, progress: 2))
        #expect(await history.record(of: id("c2")) == nil)

        #expect(await !failing.history.savePage(PageSave(chapter: id("c1"), page: 9, totalPages: 40, scrollPosition: 0.9)))
        #expect(await store.seed.lastRead(of: manga) == date(-1000))
        #expect(await history.record(of: id("c1")) == HistoryRecord(chapterId: id("c1"), progress: 2, total: 38, completed: false, dateRead: date(100), scrollPosition: 0.5))

        #expect(await !failing.history.remove(chapters: [id("c1")]))
        #expect(await !failing.history.removeAll(of: manga))
        #expect(await history.hasHistory(of: manga))

        let session = HistoryManager.ReadingSessionData(startDate: date(1), endDate: date(2), pagesRead: 1)
        #expect(await !failing.sessions.add(session, chapter: id("c3")))
        #expect(await history.record(of: id("c3")) == nil)
        await store.tearDown()
    }
}
