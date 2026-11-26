//
//  MangaDetailsContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-5): the manga screen saves its chapter filters by writing the whole manga, as it did
//  (`updateMangaDetails`, spec §1.5 nº 15): the fields the user edited stay; the chapter flags, the language, the
//  scanlators and the next update time are always written, nil included.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct MangaDetailsContractTests {
    private let id = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")

    private func manga(title: String, cover: String?, authors: [String]?, next: Int?) -> AidokuRunner.Manga {
        AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: title, cover: cover, authors: authors, nextUpdateTime: next)
    }

    @Test(arguments: repositoryFixtures)
    func theEditedFieldsStayAndTheFiltersAreWritten(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repo = store.repos.manga
        await store.seed.setManga(id, MangaSeed(flags: 1, language: "es", scanlators: ["A"], cover: "https://example.com/old.jpg", title: "Viejo", author: "Autor"))
        // the user set the cover: an edited field
        await repo.setCover(id, url: "https://example.com/mine.jpg", original: false)

        let filters = MangaChapterFilters(flags: 6, language: "en", scanlators: ["B", "C"])
        #expect(await repo.updateDetails(
            manga(title: "Nuevo", cover: "https://example.com/new.jpg", authors: ["Otra"], next: 1_900_000_000),
            filters: filters
        ))
        let stored = try #require(await repo.manga(id))
        #expect(stored.title == "Nuevo")
        #expect(stored.authors == ["Otra"])
        #expect(stored.cover == "https://example.com/mine.jpg")
        #expect(stored.nextUpdateTime == 1_900_000_000)
        #expect(await repo.chapterFilters(id) == filters)
        #expect(await repo.hasEditedKey(.cover, id))

        // the four without a guard are written even when nil
        let cleared = MangaChapterFilters(flags: 0, language: nil, scanlators: nil)
        #expect(await repo.updateDetails(manga(title: "Nuevo", cover: nil, authors: nil, next: nil), filters: cleared))
        #expect(await repo.chapterFilters(id) == cleared)
        #expect(await repo.manga(id)?.nextUpdateTime == nil)
        #expect(await repo.manga(id)?.cover == "https://example.com/mine.jpg")
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func nothingStoredOrAFailedSaveIsFalse(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repo = store.repos.manga
        let filters = MangaChapterFilters(flags: 2, language: "en", scanlators: nil)
        // not stored: false, and nothing is created
        #expect(await !repo.updateDetails(manga(title: "Z", cover: nil, authors: nil, next: nil), filters: filters))
        #expect(await !repo.contains(id))
        // a failed save: false, and the stored manga is as it was
        await store.seed.setManga(id, MangaSeed(flags: 1, language: "es", title: "Viejo"))
        #expect(await !store.failingRepos.manga.updateDetails(manga(title: "Z", cover: nil, authors: nil, next: nil), filters: filters))
        #expect(await repo.chapterFilters(id) == MangaChapterFilters(flags: 1, language: "es", scanlators: nil))
        #expect(await repo.manga(id)?.title == "Viejo")
        await store.tearDown()
    }
}
