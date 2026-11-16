//
//  MangaChapterContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L6: the reads of MangaRepository, the unread and read counts of ChapterRepository and the two manga
//  reads of MainActorReads, against every fixture (each test on a store of its own). They fix what the app does
//  today (spec §1.5 nº 10, 16 and 17), the odd parts included.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct MangaChapterContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    private let other = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")
    /// the same manga key under another source is another manga
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")

    private func id(_ key: String, _ manga: MangaIdentifier? = nil) -> ChapterIdentifier {
        let manga = manga ?? self.manga
        return ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    private func chapter(_ key: String, _ language: String?, _ scanlators: [String]?, locked: Bool = false) -> AidokuRunner.Chapter {
        AidokuRunner.Chapter(key: key, scanlators: scanlators, language: language, locked: locked)
    }

    @Test(arguments: repositoryFixtures)
    func anEmptyStoreHasNoManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repo = store.repos.manga
        let chapters = store.repos.chapters
        #expect(await repo.manga(manga) == nil)
        #expect(await !repo.contains(manga))
        #expect(await repo.chapterFilters(manga) == MangaChapterFilters(flags: 0, language: nil, scanlators: nil))
        #expect(await repo.readingMode(manga) == -1)
        #expect(await !repo.hasEditedKey(.cover, manga))
        // no manga: nothing to set, and nothing is created
        #expect(await repo.setCover(manga, url: "https://example.com/c.jpg", original: false) == nil)
        #expect(await !repo.contains(manga))
        #expect(await chapters.unreadCount(of: manga) == 0)
        #expect(await chapters.unreadCounts(of: [manga, other]) == [manga: 0, other: 0])
        #expect(await chapters.unreadCounts(of: []) == [:])
        #expect(await chapters.unreadCount(of: manga, language: "es", scanlators: ["A"]) == 0)
        #expect(await chapters.readCount(of: manga, language: nil, scanlators: nil) == 0)
        let reads = store.repos.mainActorReads
        let mangaId = manga
        let (contains, mode) = await MainActor.run { (reads.manga(contains: mangaId), reads.readingMode(of: mangaId)) }
        #expect(!contains)
        #expect(mode == -1)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func aStoredMangaIsReadBack(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repo = store.repos.manga
        await store.seed.setManga(manga, MangaSeed(flags: 0b1010, language: "es", scanlators: ["A", ""], viewer: 3, cover: "https://example.com/m1.jpg"))
        await store.seed.setManga(other, MangaSeed())
        let stored = try #require(await repo.manga(manga))
        #expect(stored.sourceKey == manga.sourceKey)
        #expect(stored.key == "m1")
        #expect(stored.title == "m1")
        #expect(stored.cover == "https://example.com/m1.jpg")
        #expect(await repo.contains(manga))
        #expect(await repo.contains(other))
        #expect(await !repo.contains(sameKeyOtherSource))
        #expect(await repo.manga(sameKeyOtherSource) == nil)
        #expect(await repo.chapterFilters(manga) == MangaChapterFilters(flags: 0b1010, language: "es", scanlators: ["A", ""]))
        #expect(await repo.chapterFilters(other) == MangaChapterFilters(flags: 0, language: nil, scanlators: nil))
        #expect(await repo.chapterFilters(sameKeyOtherSource) == MangaChapterFilters(flags: 0, language: nil, scanlators: nil))
        #expect(await repo.readingMode(manga) == 3)
        #expect(await repo.readingMode(other) == 0)
        #expect(await repo.readingMode(sameKeyOtherSource) == -1)
        #expect(await !repo.hasEditedKey(.cover, manga))
        let reads = store.repos.mainActorReads
        let (mangaId, otherSource) = (manga, sameKeyOtherSource)
        let (contains, mode, containsOther, modeOther) = await MainActor.run {
            (reads.manga(contains: mangaId), reads.readingMode(of: mangaId), reads.manga(contains: otherSource), reads.readingMode(of: otherSource))
        }
        #expect(contains)
        #expect(mode == 3)
        #expect(!containsOther)
        #expect(modeOther == -1)
        await store.tearDown()
    }

    /// The cover it had comes back; the key is marked as edited, and set back as the original it is not.
    @Test(arguments: repositoryFixtures)
    func settingTheCoverMarksItAsEdited(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repo = store.repos.manga
        await store.seed.setManga(manga, MangaSeed(cover: "https://example.com/a.jpg"))
        #expect(await repo.setCover(manga, url: "https://example.com/b.jpg", original: false) == "https://example.com/a.jpg")
        #expect(await repo.manga(manga)?.cover == "https://example.com/b.jpg")
        #expect(await repo.hasEditedKey(.cover, manga))
        #expect(await repo.setCover(manga, url: "https://example.com/a.jpg", original: true) == "https://example.com/b.jpg")
        #expect(await repo.manga(manga)?.cover == "https://example.com/a.jpg")
        #expect(await !repo.hasEditedKey(.cover, manga))
        // it had no cover: nil, the same as when it does not save (as today)
        await store.seed.setManga(other, MangaSeed())
        #expect(await repo.setCover(other, url: "https://example.com/c.jpg", original: false) == nil)
        #expect(await repo.manga(other)?.cover == "https://example.com/c.jpg")
        #expect(await repo.hasEditedKey(.cover, other))
        // a failed save leaves the cover and the key as they were
        #expect(await store.failingRepos.manga.setCover(manga, url: "https://example.com/x.jpg", original: false) == nil)
        #expect(await repo.manga(manga)?.cover == "https://example.com/a.jpg")
        #expect(await !repo.hasEditedKey(.cover, manga))
        await store.tearDown()
    }

    /// §1.5 nº 10 as it is today.
    @Test(arguments: repositoryFixtures)
    func theCountsFollowLanguageAndScanlators(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let chapters = store.repos.chapters
        await store.seed.addChapters([
            chapter("c1", "es", ["A"]),
            chapter("c2", "es", ["B"]),
            chapter("c3", "en", ["A"]),
            chapter("c4", "es", nil),
            chapter("c5", "es", ["A"], locked: true),
            chapter("c6", "es", ["A"]),
            chapter("c7", "es", ["A", "B"]),
            chapter("c8", "es", ["A"]),
            chapter("c9", "es", ["A"]),
            chapter("c10", "es", ["A"], locked: true)
        ], to: manga)
        await store.seed.addChapters([chapter("c1", "es", ["A"])], to: sameKeyOtherSource)
        await store.seed.addHistory(HistorySeed(chapter: id("c6"), completed: true))
        await store.seed.addHistory(HistorySeed(chapter: id("c8"), progress: 3))
        // completed, but not linked to its chapter: it is not read for the counts
        await store.seed.addHistory(HistorySeed(chapter: id("c9"), completed: true, linked: false))
        await store.seed.addHistory(HistorySeed(chapter: id("c10"), completed: true))
        let mangaId = manga
        func unread(_ language: String?, _ scanlators: [String]?) async -> Int {
            await chapters.unreadCount(of: mangaId, language: language, scanlators: scanlators)
        }
        func read(_ language: String?, _ scanlators: [String]?) async -> Int {
            await chapters.readCount(of: mangaId, language: language, scanlators: scanlators)
        }
        // unread: never the locked ones; history missing, not completed or not linked
        #expect(await unread(nil, nil) == 7) // c1 c2 c3 c4 c7 c8 c9
        #expect(await unread("es", nil) == 6) // all but c3
        #expect(await unread("fr", nil) == 0)
        // a chapter without scanlator counts only if the filter has ""; "A, B" is not "A"
        #expect(await unread(nil, ["A"]) == 4) // c1 c3 c8 c9
        #expect(await unread(nil, ["A", ""]) == 5) // and c4
        #expect(await unread(nil, ["A, B"]) == 1) // c7
        #expect(await unread("es", ["A"]) == 3) // c1 c8 c9
        // [] is all of them
        #expect(await unread(nil, []) == 7)
        #expect(await unread("es", []) == 6)
        // read: completed and linked; the locked ones count
        #expect(await read(nil, nil) == 2) // c6 c10
        #expect(await read("es", nil) == 2)
        #expect(await read("en", nil) == 0)
        #expect(await read(nil, ["A"]) == 2)
        #expect(await read(nil, ["B"]) == 0)
        // [] is NOT all for the read count: none
        #expect(await read(nil, []) == 0)
        #expect(await read("es", []) == 0)
        // the other source's chapter with the same keys is not counted here, and counts there
        #expect(await chapters.unreadCount(of: sameKeyOtherSource, language: nil, scanlators: nil) == 1)
        await store.tearDown()
    }

    /// unreadCount(of:) and unreadCounts(of:) take each manga's stored filters ([] stored is all).
    @Test(arguments: repositoryFixtures)
    func eachMangaIsCountedWithItsOwnFilters(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let chapters = store.repos.chapters
        await store.seed.addChapters([chapter("c1", "es", ["A"]), chapter("c2", "en", ["A"]), chapter("c3", "es", ["B"]), chapter("c4", "es", nil)], to: manga)
        await store.seed.addChapters([chapter("c1", "es", ["A"]), chapter("c2", "es", ["A"])], to: other)
        await store.seed.addHistory(HistorySeed(chapter: id("c2", other), completed: true))
        await store.seed.setManga(manga, MangaSeed(language: "es", scanlators: ["A"]))
        await store.seed.setManga(other, MangaSeed(scanlators: []))
        #expect(await chapters.unreadCount(of: manga) == 1) // c1
        #expect(await chapters.unreadCount(of: other) == 1) // [] is all: c1 (c2 is read)
        // a repeated manga is counted once; one with no chapters counts 0
        #expect(await chapters.unreadCounts(of: [manga, other, sameKeyOtherSource, manga]) == [manga: 1, other: 1, sameKeyOtherSource: 0])
        await store.seed.setManga(manga, MangaSeed(language: "es", scanlators: ["A", ""]))
        #expect(await chapters.unreadCount(of: manga) == 2) // and c4
        #expect(await chapters.unreadCount(of: manga) == (await chapters.unreadCount(of: manga, language: "es", scanlators: ["A", ""])))
        await store.tearDown()
    }
}
