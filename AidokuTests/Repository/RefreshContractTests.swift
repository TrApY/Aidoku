//
//  RefreshContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L8: the library refresh of a manga and the refresh from its screen (§1.3 nº 10-11, kept apart), what
//  setChapters does with the stored chapters (§1.5 nº 11), which new chapters make an update entry (§1.5 nº 12,
//  with its odd precedence) and the updates list, against every fixture, as they are today. None of this had a test.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct RefreshContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "a")
    private let b = MangaIdentifier(sourceKey: "contract.source", mangaKey: "b")

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func chapterId(_ key: String, _ manga: MangaIdentifier? = nil) -> ChapterIdentifier {
        let manga = manga ?? a
        return ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    private func source(_ title: String, _ chapters: [AidokuRunner.Chapter]?) -> AidokuRunner.Manga {
        AidokuRunner.Manga(sourceKey: a.sourceKey, key: a.mangaKey, title: title, chapters: chapters)
    }

    private func chapter(_ key: String, _ language: String = "es", _ scanlator: String? = nil, locked: Bool = false, title: String? = nil, date: Date? = nil) -> AidokuRunner.Chapter {
        AidokuRunner.Chapter(
            key: key, title: title, dateUploaded: date, scanlators: scanlator.map { [$0] }, language: language, locked: locked
        )
    }

    private let old = LibraryDatesSeed(dateAdded: Date(timeIntervalSinceReferenceDate: 800_000_000), lastOpened: Date(timeIntervalSinceReferenceDate: 800_086_400),
        lastUpdated: Date(timeIntervalSinceReferenceDate: 800_172_800), lastUpdatedChapters: Date(timeIntervalSinceReferenceDate: 800_259_200), lastChapter: nil)

    private func inLibrary(_ store: FixtureStore, _ chapters: [AidokuRunner.Chapter], filters: MangaSeed = MangaSeed()) async {
        await store.repos.library.add(source("alpha", nil), chapters: [], defaultCategory: nil, adoptChapterFlags: nil)
        await store.seed.setManga(a, filters)
        await store.seed.addChapters(chapters, to: a)
        await store.seed.setLibraryDates(a, old)
    }

    /// Updates by id, removes repeated rows and those no longer there, recreates one that stops being locked (and
    /// gives it back as new), creates the new ones linking their history (§1.5 nº 11).
    @Test(arguments: repositoryFixtures)
    func theStoredChaptersFollowTheSource(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await inLibrary(store, [chapter("c1", locked: true), chapter("c2", title: "Viejo"), chapter("c3"), chapter("c2", title: "Repetido")])
        await store.seed.addHistory(HistorySeed(chapter: chapterId("c1"), progress: 4))
        await store.seed.addHistory(HistorySeed(chapter: chapterId("c4"), progress: 2, linked: false))
        let outcome = await repos.library.refresh(a, with: source("alpha", [
            chapter("c2", title: "Nuevo", date: day(1)), chapter("c1", date: day(3)), chapter("c4", date: day(2))
        ]), updateMetadata: false)
        #expect(outcome == RefreshOutcome(newChapterCount: 2, notifiableCount: 2, title: "alpha"))
        let stored = await repos.chapters.chapters(of: a)
        #expect(stored.map(\.key) == ["c2", "c1", "c4"])
        #expect(stored.first?.title == "Nuevo")
        #expect(stored[1].locked == false)
        #expect(await store.seed.isLinked(chapterId("c1")))
        #expect(await store.seed.isLinked(chapterId("c4")))
        #expect(await store.seed.historyRows(of: chapterId("c1")) == 1)
        #expect(await store.seed.updates(of: a) == ["c1": false, "c4": false])
        let dates = try #require(await store.seed.libraryDates(of: a))
        #expect(dates.lastChapter == day(3))
        #expect(abs(dates.lastUpdatedChapters.timeIntervalSinceNow) < 60)
        #expect(abs(dates.lastUpdated.timeIntervalSinceNow) < 60)
        #expect(dates.lastOpened == old.lastOpened)
        // the same chapters again: nothing new, nothing saved but the details asked for
        let again = await repos.library.refresh(a, with: source("alpha", [
            chapter("c2", title: "Nuevo", date: day(1)), chapter("c1", date: day(3)), chapter("c4", date: day(2))
        ]), updateMetadata: false)
        #expect(again == RefreshOutcome(newChapterCount: 0, notifiableCount: 0, title: "alpha"))
        await store.tearDown()
    }

    /// Not in the library, or without chapters: nil, and nothing is saved (not even the details).
    @Test(arguments: repositoryFixtures)
    func aRefreshWithoutChaptersSavesNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await inLibrary(store, [chapter("c1")])
        #expect(await repos.library.refresh(b, with: source("otro", [chapter("x")]), updateMetadata: true) == nil)
        #expect(await repos.library.refresh(a, with: source("beta", []), updateMetadata: true) == nil)
        #expect(await repos.library.refresh(a, with: source("beta", nil), updateMetadata: true) == nil)
        #expect(await repos.manga.manga(a)?.title == "alpha")
        #expect(await store.seed.libraryDates(of: a) == old)
        #expect(await repos.chapters.chapters(of: a).map(\.key) == ["c1"])
        // with chapters and the details: the title changes and «updated» is now, with no new chapter
        let outcome = await repos.library.refresh(a, with: source("beta", [chapter("c1")]), updateMetadata: true)
        #expect(outcome == RefreshOutcome(newChapterCount: 0, notifiableCount: 0, title: "beta"))
        let dates = try #require(await store.seed.libraryDates(of: a))
        #expect(abs(dates.lastUpdated.timeIntervalSinceNow) < 60)
        #expect(dates.lastUpdatedChapters == old.lastUpdatedChapters)
        await store.tearDown()
    }

    /// Which new chapters make an update entry: with a language filter only the language counts, the scanlator
    /// filter is not looked at (precedence of `?:`, §1.5 nº 12).
    @Test(arguments: repositoryFixtures)
    func theUpdateConditionAndItsPrecedence(fixture: any RepositoryFixture) async throws {
        let news = [chapter("x1", "es", "B"), chapter("x2", "en", "A"), chapter("x3", "es", "A"), chapter("x4", "en", nil)]
        for (filters, expected) in [
            (MangaSeed(language: "es", scanlators: ["A"]), ["x1", "x3"]),
            (MangaSeed(language: "es"), ["x1", "x3"]),
            (MangaSeed(scanlators: ["A"]), ["x2", "x3"]),
            (MangaSeed(scanlators: ["A", ""]), ["x2", "x3", "x4"]),
            (MangaSeed(scanlators: []), ["x1", "x2", "x3", "x4"]),
            (MangaSeed(), ["x1", "x2", "x3", "x4"])
        ] {
            let store = try await fixture.make()
            await inLibrary(store, [chapter("c1")], filters: filters)
            let outcome = await store.repos.library.refresh(a, with: source("alpha", [chapter("c1")] + news), updateMetadata: false)
            #expect(outcome?.newChapterCount == 4)
            #expect(outcome?.notifiableCount == expected.count, "\(filters)")
            #expect(await store.seed.updates(of: a).keys.sorted() == expected, "\(filters)")
            await store.tearDown()
        }
    }

    /// From the manga's screen: always saves the details, «updated» now and «last opened» just after it (not in
    /// incognito), the update condition with the filters it is given, and the stored manga back.
    @Test(arguments: repositoryFixtures)
    func theRefreshFromTheMangasScreen(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await inLibrary(store, [chapter("c1")], filters: MangaSeed(language: "en"))
        #expect(await repos.library.refreshOpened(b, with: source("x", nil), languageFilter: nil, scanlatorFilter: [], incognito: false) == nil)
        // no chapters: the details and the dates anyway
        let first = try #require(await repos.library.refreshOpened(a, with: source("beta", nil), languageFilter: nil, scanlatorFilter: [], incognito: false))
        #expect(first.manga.title == "beta")
        #expect(!first.foundNewChapters)
        var dates = try #require(await store.seed.libraryDates(of: a))
        #expect(abs(dates.lastOpened.timeIntervalSince(dates.lastUpdated) - 1) < 0.001)
        #expect(abs(dates.lastUpdated.timeIntervalSinceNow) < 60)
        #expect(dates.lastUpdatedChapters == old.lastUpdatedChapters)
        // the filters given, not the stored ones (the stored language would leave x2 out)
        await store.seed.setLibraryDates(a, old)
        let second = try #require(await repos.library.refreshOpened(
            a, with: source("beta", [chapter("c1"), chapter("x1", "es", "B"), chapter("x2", "es", "A")]),
            languageFilter: nil, scanlatorFilter: ["A"], incognito: true
        ))
        #expect(second.foundNewChapters)
        #expect(await store.seed.updates(of: a) == ["x2": false])
        dates = try #require(await store.seed.libraryDates(of: a))
        #expect(dates.lastOpened == old.lastOpened)
        #expect(abs(dates.lastUpdatedChapters.timeIntervalSinceNow) < 60)
        await store.tearDown()
    }

    /// The updates list: newest first with its manga; marking a manga's as viewed gives back the unviewed ones once;
    /// removing.
    @Test(arguments: repositoryFixtures)
    func theUpdatesList(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        #expect(await repos.mangaUpdates.recent(limit: 25, offset: 0).isEmpty)
        await inLibrary(store, [chapter("c1")])
        await repos.library.refresh(a, with: source("alpha", [chapter("c1"), chapter("n1", title: "", date: day(1))]), updateMetadata: false)
        try await Task.sleep(for: .milliseconds(20))
        await repos.library.refresh(a, with: source("alpha", [chapter("c1"), chapter("n1", title: "", date: day(1)), chapter("n2", "es", "S")]), updateMetadata: false)
        let recent = await repos.mangaUpdates.recent(limit: 25, offset: 0)
        #expect(recent.map(\.chapterId.chapterKey) == ["n2", "n1"])
        #expect(recent.allSatisfy { $0.manga.title == "alpha" && !$0.viewed && $0.date != nil })
        // the chapter as the list read it: "" is nil; its place in the source
        #expect(recent.last?.chapter?.title == nil)
        #expect(recent.last?.chapter?.dateUploaded == day(1))
        #expect(recent.last?.chapterSourceOrder == 1)
        #expect(recent.first?.chapter?.scanlators == ["S"])
        #expect(recent.first?.chapterSourceOrder == 2)
        #expect(await repos.mangaUpdates.recent(limit: 1, offset: 1).map(\.chapterId.chapterKey) == ["n1"])

        let viewed = await repos.mangaUpdates.markViewed(of: a)
        #expect(Set(viewed.map(\.chapterId.chapterKey)) == ["n1", "n2"])
        #expect(viewed.allSatisfy { $0.viewed })
        #expect(await repos.mangaUpdates.markViewed(of: a).isEmpty)
        #expect(await store.seed.updates(of: a) == ["n1": true, "n2": true])

        #expect(await repos.mangaUpdates.remove([chapterId("n1"), chapterId("zz")]))
        #expect(await store.seed.updates(of: a) == ["n2": true])
        // an update whose manga is no longer stored is left out
        await repos.library.remove(a)
        #expect(await repos.mangaUpdates.recent(limit: 25, offset: 0).isEmpty)
        await store.tearDown()
    }
}
