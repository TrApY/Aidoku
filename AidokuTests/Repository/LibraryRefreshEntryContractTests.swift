//
//  LibraryRefreshEntryContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12a (D-L12-3): what the library refresh reads of each entry. The refresh goes through the old
//  `Manga`: it keys its results by that manga's hash (source and key), skips by its fields and gives the source its
//  `toNew()`. Two manga with the same key in two sources are two entries.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibraryRefreshEntryContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    /// the same key in another source
    private let b = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")
    /// stored, not in the library
    private let out = MangaIdentifier(sourceKey: "contract.source", mangaKey: "fuera")

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func seed(_ store: FixtureStore) async {
        await store.addToLibrary([a, b])
        await store.seed.setManga(a, MangaSeed(
            flags: 3, language: "es", scanlators: ["A"], viewer: 4, cover: "https://example.com/a.jpg",
            title: "Uno", author: "Autora, Otra", url: "https://example.com/a", status: 2, nsfw: 1
        ))
        await store.seed.setManga(b, MangaSeed(language: "en", title: "Otro"))
        await store.seed.setManga(out, MangaSeed(title: "Fuera"))
        await store.seed.setLibraryDates(a, LibraryDatesSeed(
            dateAdded: day(1), lastOpened: day(2), lastUpdated: day(3), lastUpdatedChapters: day(4), lastChapter: day(5), lastRead: day(6)
        ))
    }

    @Test(arguments: repositoryFixtures)
    func eachEntryKeepsItsIdentityAndItsFields(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        let entries = await store.repos.library.refreshEntries(category: nil)
        try #require(entries.count == 2)
        // two entries, two keys of the refresh's results (the old Manga's hash: source and key)
        let old = entries.map { $0.toManga() }
        #expect(Set(old.map(\.identifier)) == [a, b])
        #expect(Set(old.map(\.hashValue)).count == 2)
        #expect(Set(old).count == 2)

        let first = try #require(entries.first { $0.sourceId == a.sourceKey })
        #expect(first.id == "m1")
        #expect(first.title == "Uno")
        #expect(first.author == "Autora, Otra")
        #expect(first.coverUrl == URL(string: "https://example.com/a.jpg"))
        #expect(first.url == URL(string: "https://example.com/a"))
        #expect(first.status == PublishingStatus(rawValue: 2))
        #expect(first.nsfw == MangaContentRating(rawValue: 1))
        #expect(first.viewer == MangaViewer(rawValue: 4))
        #expect(first.updateStrategy == .always)
        #expect(first.nextUpdateTime == nil)
        #expect(first.chapterFlags == 3)
        #expect(first.langFilter == "es")
        #expect(first.scanlatorFilter == ["A"])
        #expect(first.dateAdded == day(1))
        #expect(first.lastOpened == day(2))
        #expect(first.lastUpdated == day(3))
        #expect(first.lastUpdatedChapters == day(4))
        #expect(first.lastChapter == day(5))
        #expect(first.lastRead == day(6))

        let second = try #require(entries.first { $0.sourceId == b.sourceKey })
        #expect(second.id == "m1")
        #expect(second.title == "Otro")
        #expect(second.langFilter == "en")
        #expect(second.scanlatorFilter == nil)

        // what the source gets: the old Manga's toNew(), field for field
        let manga = first.toManga().toNew()
        #expect(manga.sourceKey == a.sourceKey)
        #expect(manga.key == "m1")
        #expect(manga.title == "Uno")
        #expect(manga.cover == "https://example.com/a.jpg")
        #expect(manga.authors == ["Autora", "Otra"])
        #expect(manga.url == URL(string: "https://example.com/a"))
        #expect(manga.updateStrategy == .always)
        // and the old Manga keeps the fields it was read with
        let back = first.toManga()
        #expect(LibraryRefreshEntry(back) == first)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func aCategoryGivesItsEntriesOnly(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        await store.repos.categories.create(title: "X")
        await store.repos.categories.assign([b], add: ["X"])
        let inX = await store.repos.library.refreshEntries(category: "X")
        #expect(inX.map { MangaIdentifier(sourceKey: $0.sourceId, mangaKey: $0.id) } == [b])
        #expect(await store.repos.library.refreshEntries(category: "Y").isEmpty)
        // an entry without a manga is left out
        await store.seed.addLibraryEntryWithoutManga()
        #expect(await store.repos.library.refreshEntries(category: nil).count == 2)
        await store.tearDown()
    }
}
