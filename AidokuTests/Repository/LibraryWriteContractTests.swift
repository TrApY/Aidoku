//
//  LibraryWriteContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L7: adding to and removing from the library, undoing a removal, «last opened», against every
//  fixture, as they are today (§1.3 nº 6-9, §1.5 nº 7-8). The local order (ChapterSortMemory) and download ahead
//  stay with the services: the repository only gets and gives the chapter flags.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibraryWriteContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "a")
    private let b = MangaIdentifier(sourceKey: "contract.source", mangaKey: "b")
    private let c = MangaIdentifier(sourceKey: "contract.other", mangaKey: "c")

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func manga(_ id: MangaIdentifier, _ title: String) -> AidokuRunner.Manga {
        AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: title)
    }

    private func chapters() -> [AidokuRunner.Chapter] {
        [
            AidokuRunner.Chapter(key: "c2", title: "", chapterNumber: 2, dateUploaded: day(2), scanlators: [""]),
            AidokuRunner.Chapter(key: "c1", title: "Uno", chapterNumber: 1, dateUploaded: day(1))
        ]
    }

    private func track(_ id: MangaIdentifier, _ tracker: String, offset: Int = 0) -> TrackItem {
        TrackItem(id: "\(tracker)-\(id.mangaKey)", trackerId: tracker, mangaId: id, title: "T", chapterOffset: offset)
    }

    @Test(arguments: repositoryFixtures)
    func addingPutsMangaChaptersAndCategory(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await repos.categories.create(title: "Defecto")
        #expect(await repos.library.add(manga(a, "alpha"), chapters: chapters(), defaultCategory: "Defecto", adoptChapterFlags: nil))
        #expect(await repos.library.contains(a))
        #expect(await repos.manga.manga(a)?.title == "alpha")
        #expect(await repos.chapters.chapters(of: a).map(\.key) == ["c2", "c1"])
        #expect(await repos.categories.categories(of: a) == ["Defecto"])
        let dates = try #require(await store.seed.libraryDates(of: a))
        // the last chapter is the newest upload; the rest start now
        #expect(dates.lastChapter == day(2))
        #expect(abs(dates.dateAdded.timeIntervalSinceNow) < 60)
        // a default category that does not exist is not created; nil: none
        #expect(await repos.library.add(manga(b, "bravo"), chapters: [], defaultCategory: "Nope", adoptChapterFlags: nil))
        #expect(await repos.categories.categories(of: b).isEmpty)
        #expect(await repos.categories.contains(title: "Nope") == false)
        #expect(try #require(await store.seed.libraryDates(of: b)).lastChapter == nil)
        await store.tearDown()
    }

    /// The flags of the stored manga go to the closure; what it gives back is stored, nil keeps them.
    @Test(arguments: repositoryFixtures)
    func addingAdoptsChapterFlags(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await store.seed.setManga(a, MangaSeed(flags: 4))
        let seen = FlagsBox()
        await repos.library.add(manga(a, "alpha"), chapters: [], defaultCategory: nil, adoptChapterFlags: { flags in
            seen.set(flags)
            return flags | 0b10_0000
        })
        #expect(seen.value == 4)
        #expect(await repos.manga.chapterFilters(a).flags == 4 | 0b10_0000)
        await repos.library.add(manga(b, "bravo"), chapters: [], defaultCategory: nil, adoptChapterFlags: { _ in nil })
        #expect(await repos.manga.chapterFilters(b).flags == 0)
        await store.tearDown()
    }

    /// Adding again does not look for the entry it has (§1.5 nº 8): a second entry is made and takes the manga (the
    /// relation is one to one), so the manga is still in the library once.
    @Test(arguments: repositoryFixtures)
    func addingTwiceKeepsOneEntryWithTheManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await repos.library.add(manga(a, "alpha"), chapters: [], defaultCategory: nil, adoptChapterFlags: nil)
        await repos.library.add(manga(a, "alpha"), chapters: [], defaultCategory: nil, adoptChapterFlags: nil)
        #expect(await repos.library.entries(category: nil).map(\.key) == ["a"])
        #expect(await repos.library.countInLibrary(sourceKeys: [a.sourceKey]) == 1)
        // a failed save adds nothing
        #expect(await !store.failingRepos.library.add(manga(b, "bravo"), chapters: [], defaultCategory: nil, adoptChapterFlags: nil))
        #expect(await !repos.library.contains(b))
        await store.tearDown()
    }

    private func seedTwo(_ store: FixtureStore) async {
        let repos = store.repos
        await repos.library.add(manga(a, "alpha"), chapters: chapters(), defaultCategory: nil, adoptChapterFlags: nil)
        await repos.library.add(manga(b, "bravo"), chapters: chapters(), defaultCategory: nil, adoptChapterFlags: nil)
        await repos.library.add(manga(c, "charlie"), chapters: chapters(), defaultCategory: nil, adoptChapterFlags: nil)
        await store.seed.setManga(a, MangaSeed(flags: 7))
        await repos.tracks.add(track(a, "t1"))
        await repos.tracks.add(track(b, "t1"))
        await repos.tracks.add(track(c, "t1"))
        await store.seed.addHistory(HistorySeed(chapter: ChapterIdentifier(sourceKey: a.sourceKey, mangaKey: "a", chapterKey: "c1"), progress: 3))
    }

    /// One manga: the manga, its chapters and its tracks go; its history stays; the others are untouched.
    @Test(arguments: repositoryFixtures)
    func removingOne(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedTwo(store)
        let removed = await repos.library.remove(a)
        #expect(removed == LibraryRemovalResult(chapterFlagsBefore: [a: 7], saved: true))
        #expect(await !repos.library.contains(a))
        #expect(await !repos.manga.contains(a))
        #expect(await repos.chapters.chapters(of: a).isEmpty)
        #expect(await repos.tracks.items(of: a).isEmpty)
        #expect(await repos.history.hasHistory(of: a))
        #expect(await repos.library.contains(b))
        #expect(await repos.chapters.chapters(of: b).count == 2)
        #expect(await repos.tracks.items(of: b).count == 1)
        // not stored: nothing before, saved
        #expect(await repos.library.remove(MangaIdentifier(sourceKey: "contract.source", mangaKey: "z"))
            == LibraryRemovalResult(chapterFlagsBefore: [:], saved: true))
        // a failed save keeps everything (and still says the flags it read)
        let failed = await store.failingRepos.library.remove(b)
        #expect(failed == LibraryRemovalResult(chapterFlagsBefore: [b: 0], saved: false))
        #expect(await repos.library.contains(b))
        await store.tearDown()
    }

    /// Several at once: the same result through the other path (§1.5 nº 7).
    @Test(arguments: repositoryFixtures)
    func removingSeveral(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedTwo(store)
        let missing = MangaIdentifier(sourceKey: "contract.source", mangaKey: "z")
        let removed = await repos.library.remove([a, b, missing])
        #expect(removed == LibraryRemovalResult(chapterFlagsBefore: [a: 7, b: 0], saved: true))
        for id in [a, b] {
            #expect(await !repos.library.contains(id))
            #expect(await !repos.manga.contains(id))
            #expect(await repos.chapters.chapters(of: id).isEmpty)
            #expect(await repos.tracks.items(of: id).isEmpty)
        }
        #expect(await repos.history.hasHistory(of: a))
        #expect(await repos.library.contains(c))
        #expect(await repos.tracks.items(of: c).count == 1)
        #expect(await repos.library.remove([]) == LibraryRemovalResult(chapterFlagsBefore: [:], saved: true))
        let failed = await store.failingRepos.library.remove([c])
        #expect(!failed.saved)
        #expect(await repos.library.contains(c))
        await store.tearDown()
    }

    /// The snapshot before removing and putting it back (undo).
    @Test(arguments: repositoryFixtures)
    func undoingARemoval(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await repos.library.add(manga(a, "alpha"), chapters: chapters(), defaultCategory: nil, adoptChapterFlags: nil)
        await repos.tracks.add(track(a, "t1", offset: 5))
        await repos.categories.create(title: "X")
        await repos.categories.assign([a], add: ["X"])
        await store.seed.setLibraryDates(a, LibraryDatesSeed(
            dateAdded: day(1), lastOpened: day(2), lastUpdated: day(3), lastUpdatedChapters: day(4), lastChapter: day(5), lastRead: nil
        ))
        let missing = MangaIdentifier(sourceKey: "contract.source", mangaKey: "z")
        let snapshots = await repos.library.snapshot([missing, a])
        try #require(snapshots.count == 1)
        let snapshot = snapshots[0]
        #expect(snapshot.manga.key == "a")
        #expect(snapshot.manga.title == "alpha")
        // chapters as the old Chapter read them: "" is nil
        #expect(snapshot.chapters.map(\.key) == ["c2", "c1"])
        #expect(snapshot.chapters[0].title == nil)
        #expect(snapshot.chapters[0].scanlators == nil)
        #expect(snapshot.dates == LibraryDates(dateAdded: day(1), lastOpened: day(2), lastUpdated: day(3), lastUpdatedChapters: day(4), lastChapter: day(5), lastRead: nil))
        #expect(snapshot.tracks.map(\.chapterOffset) == [5])
        #expect(snapshot.categories == ["X"])

        await repos.library.remove(a)
        // the category was removed meanwhile: restoring creates it again
        await repos.categories.remove(title: "X")
        #expect(await repos.library.restore(snapshot))
        #expect(await repos.library.contains(a))
        #expect(await repos.chapters.chapters(of: a).map(\.key) == ["c2", "c1"])
        #expect(await repos.categories.categories(of: a) == ["X"])
        let tracks = await repos.tracks.items(of: a)
        #expect(tracks.map(\.id) == ["t1-a"])
        // the chapter offset is not restored (as today)
        #expect(tracks.map(\.chapterOffset) == [0])
        let dates = try #require(await store.seed.libraryDates(of: a))
        #expect(dates == LibraryDatesSeed(dateAdded: day(1), lastOpened: day(2), lastUpdated: day(3), lastUpdatedChapters: day(4), lastChapter: day(5), lastRead: nil))
        // a failed save puts nothing back
        await repos.library.remove(a)
        #expect(await !store.failingRepos.library.restore(snapshot))
        #expect(await !repos.library.contains(a))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func openingAndTheOldDefaultDate(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await repos.library.add(manga(a, "alpha"), chapters: [], defaultCategory: nil, adoptChapterFlags: nil)
        let old = Date(timeIntervalSince1970: 21600)
        await store.seed.setLibraryDates(a, LibraryDatesSeed(dateAdded: day(1), lastOpened: day(2), lastUpdated: day(3), lastUpdatedChapters: old))
        #expect(await repos.library.markOpened(a))
        let opened = try #require(await store.seed.libraryDates(of: a))
        #expect(abs(opened.lastOpened.timeIntervalSinceNow) < 60)
        // not in the library: nothing to do
        #expect(await repos.library.markOpened(b))
        #expect(await store.seed.libraryDates(of: b) == nil)
        #expect(await !store.failingRepos.library.markOpened(a))
        // the old default date is changed but never saved (as today)
        await repos.library.resetLastUpdatedChapters()
        #expect(try #require(await store.seed.libraryDates(of: a)).lastUpdatedChapters == old)
        await store.tearDown()
    }

    /// A local file (a manga with a file info) loses only its library entry, by both paths (§1.5 nº 7, bajo nº 23):
    /// the manga and its chapters with a file stay; the other chapters and its tracks go.
    @Test(arguments: repositoryFixtures)
    func removingALocalFileKeepsItsMangaAndItsFiles(fixture: any RepositoryFixture) async throws {
        for several in [false, true] {
            let store = try await fixture.make()
            let repos = store.repos
            let local = MangaIdentifier(sourceKey: "contract.local", mangaKey: "fichero")
            await store.addToLibrary([local, b])
            await store.seed.addChapters([.init(key: "f1"), .init(key: "f2")], to: local)
            await store.seed.setLocalFile(local, chapters: ["f1"])
            await repos.tracks.add(track(local, "t1"))
            let removed = several ? await repos.library.remove([local]) : await repos.library.remove(local)
            #expect(removed.saved, "several: \(several)")
            #expect(await !repos.library.contains(local), "several: \(several)")
            #expect(await repos.manga.contains(local), "several: \(several)")
            #expect(await repos.chapters.chapters(of: local).map(\.key) == ["f1"], "several: \(several)")
            #expect(await repos.tracks.items(of: local).isEmpty, "several: \(several)")
            #expect(await repos.library.contains(b), "several: \(several)")
            await store.tearDown()
        }
    }

    /// More than a batch (101 at once, the batches are of 100): all of them go (bajo nº 23).
    @Test(arguments: repositoryFixtures)
    func removingMoreThanABatchAtOnce(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        let ids = (0..<101).map { MangaIdentifier(sourceKey: "contract.source", mangaKey: "n\($0)") }
        await store.addToLibrary(ids + [c])
        let last = try #require(ids.last)
        await store.seed.addChapters([.init(key: "l1")], to: last)
        await repos.tracks.add(track(last, "t1"))
        #expect(await repos.library.contained(in: ids).count == 101)
        let removed = await repos.library.remove(ids)
        #expect(removed.saved)
        #expect(removed.chapterFlagsBefore.count == 101)
        #expect(await repos.library.contained(in: ids).isEmpty)
        #expect(await !repos.manga.contains(last))
        #expect(await repos.chapters.chapters(of: last).isEmpty)
        #expect(await repos.tracks.items(of: last).isEmpty)
        #expect(await repos.library.contains(c))
        await store.tearDown()
    }
}

/// What the adoption closure was given.
final class FlagsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? { lock.withLock { stored } }
    func set(_ value: Int) { lock.withLock { stored = value } }
}

extension LibraryDatesSeed: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dateAdded == rhs.dateAdded && lhs.lastOpened == rhs.lastOpened && lhs.lastUpdated == rhs.lastUpdated
            && lhs.lastUpdatedChapters == rhs.lastUpdatedChapters && lhs.lastChapter == rhs.lastChapter && lhs.lastRead == rhs.lastRead
    }
}
