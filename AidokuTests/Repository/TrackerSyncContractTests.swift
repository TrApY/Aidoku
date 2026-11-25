//
//  TrackerSyncContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L11b (D-L11-6): HistoryRepository.applyTrackerSync reads the local history, plans and writes in one
//  context and one save, against every fixture; and the service writes the journal only when it saved.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct TrackerSyncContractTests {
    private let key = "contract.\(UUID().uuidString)"
    private var mangaId: MangaIdentifier { MangaIdentifier(sourceKey: key, mangaKey: "m") }
    private var manga: AidokuRunner.Manga { AidokuRunner.Manga(sourceKey: key, key: "m", title: "Sincronizado") }

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func chapter(_ chapterKey: String) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: key, mangaKey: "m", chapterKey: chapterKey)
    }

    /// In the library, last read on day 1, chapters c1-c4; c1 at page 3 on day 2, c2 completed on day 2.
    private func seed(_ store: FixtureStore) async {
        let chapters = (1...4).reversed().map { AidokuRunner.Chapter(key: "c\($0)", chapterNumber: Float($0)) }
        await store.repos.library.add(manga, chapters: chapters, defaultCategory: nil, adoptChapterFlags: nil)
        await store.seed.setLastRead(day(1), of: mangaId)
        await store.seed.addHistory(HistorySeed(chapter: chapter("c1"), progress: 3, total: 10, dateRead: day(2)))
        await store.seed.addHistory(HistorySeed(chapter: chapter("c2"), total: 0, completed: true, dateRead: day(2)))
    }

    private var remote: [String: ChapterReadProgress] {
        [
            "c1": .init(completed: true, page: 0, date: day(4)), // newer: completed
            "c2": .init(completed: true, page: 0, date: day(5)), // already completed: nothing
            "c3": .init(completed: false, page: 6, date: day(3)), // no history: its page
            "c4": .init(completed: true, page: 0, date: nil), // no history, no date: completed now
        ]
    }

    /// What the plan says is written, in one save, and the manga is read on the latest date.
    @Test(arguments: repositoryFixtures)
    func thePlanIsWritten(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seed(store)
        let result = await repos.history.applyTrackerSync(mangaId: mangaId, remote: remote)
        #expect(result.saved)
        #expect(Set(result.completed) == ["c1", "c4"])
        #expect(result.progressed == ["c3": 6])
        #expect(result.plan.mangaRead == day(4))
        let c1 = try #require(await repos.history.record(of: chapter("c1")))
        #expect(c1.completed && c1.dateRead == day(4) && c1.progress == 10 && c1.total == 10) // completed: at its last page
        let c2 = try #require(await repos.history.record(of: chapter("c2")))
        #expect(c2.completed && c2.dateRead == day(2))
        let c3 = try #require(await repos.history.record(of: chapter("c3")))
        #expect(!c3.completed && c3.progress == 6 && c3.dateRead == day(3))
        let c4 = try #require(await repos.history.record(of: chapter("c4")))
        let c4Date = try #require(c4.dateRead)
        #expect(c4.completed && abs(c4Date.timeIntervalSinceNow) < 60)
        #expect(await store.seed.lastRead(of: mangaId) == day(4))
        await store.tearDown()
    }

    /// Nothing to write: no read date for the manga.
    @Test(arguments: repositoryFixtures)
    func nothingNewLeavesTheMangaAlone(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        let result = await store.repos.history.applyTrackerSync(mangaId: mangaId, remote: ["c1": .init(completed: true, page: 0, date: day(1))])
        #expect(result.saved)
        #expect(result.plan == TrackerSyncPlan())
        #expect(try #require(await store.repos.history.record(of: chapter("c1"))).progress == 3)
        #expect(await store.seed.lastRead(of: mangaId) == day(1))
        await store.tearDown()
    }

    /// A failed save: not saved, and nothing written (the plan still says what it would have done).
    @Test(arguments: repositoryFixtures)
    func aFailedSaveWritesNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seed(store)
        let result = await store.failingRepos.history.applyTrackerSync(mangaId: mangaId, remote: remote)
        #expect(!result.saved)
        #expect(Set(result.completed) == ["c1", "c4"])
        #expect(try #require(await repos.history.record(of: chapter("c1"))).completed == false)
        #expect(await repos.history.record(of: chapter("c3")) == nil)
        #expect(await repos.history.record(of: chapter("c4")) == nil)
        #expect(await store.seed.lastRead(of: mangaId) == day(1))
        await store.tearDown()
    }
}

/// The journal of a sync: the completions, with the trackers and the detail, only when it saved (SUWA-12 H3).
@Suite(.serialized) struct TrackerSyncJournalTests {
    private let key = "contract.\(UUID().uuidString)"

    private func lines() -> [[String]] {
        CompletionJournal.lines()
            .filter { $0.contains("\t\(key)\tm\t") }
            .map { Array($0.split(separator: "\t", omittingEmptySubsequences: false).dropFirst(3).map(String.init)) }
    }

    private func sync(saved: Bool) -> TrackerSyncResult {
        TrackerSyncResult(
            saved: saved,
            plan: TrackerSyncPlan(steps: [
                .complete(chapterKey: "c1", date: .now, journalDetail: "fecha ninguna, local sin historial"),
                .progress(chapterKey: "c2", page: 3, date: .now),
                .complete(chapterKey: "c3", date: .now, journalDetail: "fecha x, local pág 2/9"),
            ])
        )
    }

    @Test func aSyncThatDidNotSaveWritesNoJournal() {
        TrackerManager.recordSyncJournal(sync(saved: false), manga: AidokuRunner.Manga(sourceKey: key, key: "m", title: "m"), trackerIds: "a,b")
        #expect(lines() == [])
    }

    @Test func aSavedSyncWritesItsCompletions() {
        TrackerManager.recordSyncJournal(sync(saved: true), manga: AidokuRunner.Manga(sourceKey: key, key: "m", title: "m"), trackerIds: "a,b")
        #expect(lines() == [
            ["c1", "sincronización a,b", "fecha ninguna, local sin historial"],
            ["c3", "sincronización a,b", "fecha x, local pág 2/9"],
        ])
    }
}
