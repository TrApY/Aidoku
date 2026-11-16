//
//  LibraryReadContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L7: the other library reads (by source, all or by category, one manga, the sources, the counts by
//  source), against every fixture, as they are today.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibraryReadContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "a")
    private let b = MangaIdentifier(sourceKey: "contract.other", mangaKey: "b")
    private let c = MangaIdentifier(sourceKey: "contract.source", mangaKey: "c")
    /// stored, not in the library
    private let outside = MangaIdentifier(sourceKey: "contract.third", mangaKey: "d")

    private func seed(_ store: FixtureStore) async {
        await store.addToLibrary([a, b, c])
        await store.seed.setManga(a, MangaSeed(cover: "https://example.com/a.jpg", title: "alpha"))
        await store.seed.setManga(outside, MangaSeed(title: "delta"))
        await store.repos.categories.create(title: "X")
        await store.repos.categories.assign([a, b], add: ["X"])
    }

    private func keys(_ manga: [AidokuRunner.Manga]) -> [String] { manga.map(\.key).sorted() }

    @Test(arguments: repositoryFixtures)
    func anEmptyLibraryHasNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await store.seed.setManga(outside, MangaSeed())
        let library = store.repos.library
        #expect(await library.entries(sourceKey: outside.sourceKey).isEmpty)
        #expect(await library.entries(category: nil).isEmpty)
        #expect(await library.entry(outside) == nil)
        #expect(await library.sourceKeysInLibrary().isEmpty)
        #expect(await library.countInLibrary(sourceKeys: [outside.sourceKey]) == 0)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func theLibraryIsReadBySourceAndCategory(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        let library = store.repos.library
        #expect(keys(await library.entries(sourceKey: "contract.source")) == ["a", "c"])
        #expect(keys(await library.entries(sourceKey: "contract.third")) == [])
        #expect(keys(await library.entries(category: nil)) == ["a", "b", "c"])
        #expect(keys(await library.entries(category: "X")) == ["a", "b"])
        #expect(keys(await library.entries(category: "Nope")) == [])
        let alpha = try #require(await library.entries(sourceKey: "contract.source").first { $0.key == "a" })
        #expect(alpha.title == "alpha")
        #expect(alpha.cover == "https://example.com/a.jpg")
        #expect(await library.sourceKeysInLibrary() == ["contract.source", "contract.other"])
        #expect(await library.countInLibrary(sourceKeys: ["contract.source"]) == 2)
        #expect(await library.countInLibrary(sourceKeys: ["contract.source", "contract.other", "contract.third"]) == 3)
        #expect(await library.countInLibrary(sourceKeys: []) == 0)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func oneMangaOfTheLibrary(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        let library = store.repos.library
        let alpha = try #require(await library.entry(a))
        #expect(alpha.sourceKey == a.sourceKey)
        #expect(alpha.key == "a")
        #expect(alpha.title == "alpha")
        #expect(alpha.cover == "https://example.com/a.jpg")
        // stored but not in the library, and not stored
        #expect(await library.entry(outside) == nil)
        #expect(await library.entry(MangaIdentifier(sourceKey: "contract.source", mangaKey: "z")) == nil)
        await store.tearDown()
    }

    /// A manga stored twice and in the library twice (as a sync can leave it): the reads by source and the counts
    /// see both entries; the sources, once.
    @Test(arguments: repositoryFixtures)
    func aRepeatedEntryIsSeenTwice(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        await store.seed.addDuplicateLibraryEntry(a)
        let library = store.repos.library
        #expect(keys(await library.entries(sourceKey: "contract.source")) == ["a", "a", "c"])
        #expect(keys(await library.entries(category: nil)) == ["a", "a", "b", "c"])
        #expect(await library.countInLibrary(sourceKeys: ["contract.source"]) == 3)
        #expect(await library.sourceKeysInLibrary() == ["contract.source", "contract.other"])
        #expect(await library.entry(a)?.key == "a")
        await store.tearDown()
    }
}
