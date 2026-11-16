//
//  LibraryQueryContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L7: the library screen's query (LibraryViewModel.loadLibrary before L7), against every fixture. It
//  had no test at all: this fixes what it does today, the odd parts included (every filter, «uncategorized», the
//  updated-chapters pin, each order, repeated manga, what the screen still applies).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibraryQueryContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "a")
    private let b = MangaIdentifier(sourceKey: "contract.other", mangaKey: "b")
    private let c = MangaIdentifier(sourceKey: "contract.source", mangaKey: "c")

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func filter(_ type: LibraryFilter.FilterMethod, _ value: String? = nil, exclude: Bool = false) -> LibraryFilter {
        LibraryFilter(type: type, value: value, exclude: exclude)
    }

    private func page(
        _ store: FixtureStore,
        _ scope: LibraryQuery.Scope = .all,
        sort: LibraryQuery.Sort = .title,
        ascending: Bool = true,
        filters: [LibraryFilter] = [],
        pin: Bool = false
    ) async throws -> LibraryPage {
        let query = LibraryQuery(scope: scope, sort: sort, ascending: ascending, filters: filters, pinUpdatedChapters: pin)
        return try #require(await store.repos.library.page(query))
    }

    private func keys(_ items: [MangaInfo]) -> [String] { items.map(\.id.mangaKey) }

    private func shown(_ store: FixtureStore, _ filters: [LibraryFilter], _ scope: LibraryQuery.Scope = .all) async throws -> Set<String> {
        let result = try await page(store, scope, filters: filters)
        return Set(keys(result.pinned + result.manga))
    }

    /// alpha: completed, safe, 3 chapters, tracked, read (linked history), in X; bravo: ongoing, nsfw, 1 chapter,
    /// in X and Y; charlie: suggestive, no chapters, a history row not linked, no category. A manga stored but not
    /// in the library is never shown.
    private func seedLibrary(_ store: FixtureStore) async {
        await store.addToLibrary([a, b, c])
        await store.seed.setManga(a, MangaSeed(cover: "https://example.com/a.jpg", title: "alpha", author: "Autora", url: "https://example.com/a", status: 2, nsfw: 0))
        await store.seed.setManga(b, MangaSeed(title: "bravo", status: 1, nsfw: 2))
        await store.seed.setManga(c, MangaSeed(title: "charlie", nsfw: 1))
        await store.seed.setManga(MangaIdentifier(sourceKey: "contract.third", mangaKey: "fuera"), MangaSeed(title: "aaa"))
        await store.seed.addChapters([.init(key: "a1"), .init(key: "a2"), .init(key: "a3")], to: a)
        await store.seed.addChapters([.init(key: "b1")], to: b)
        await store.seed.addHistory(HistorySeed(chapter: ChapterIdentifier(sourceKey: a.sourceKey, mangaKey: a.mangaKey, chapterKey: "a1"), progress: 2))
        await store.seed.addHistory(HistorySeed(chapter: ChapterIdentifier(sourceKey: c.sourceKey, mangaKey: c.mangaKey, chapterKey: "x"), linked: false))
        await store.repos.tracks.add(TrackItem(id: "t1", trackerId: "contract.tracker", mangaId: a, title: nil, chapterOffset: 0))
        await store.repos.categories.create(title: "X")
        await store.repos.categories.create(title: "Y")
        await store.repos.categories.assign([a, b], add: ["X"])
        await store.repos.categories.assign([b], add: ["Y"])
        await store.seed.setLibraryDates(a, LibraryDatesSeed(dateAdded: day(1), lastOpened: day(5), lastUpdated: day(3), lastUpdatedChapters: day(6), lastChapter: day(2), lastRead: day(4)))
        await store.seed.setLibraryDates(b, LibraryDatesSeed(dateAdded: day(2), lastOpened: day(1), lastUpdated: day(1), lastUpdatedChapters: day(1), lastChapter: nil, lastRead: day(1)))
        await store.seed.setLibraryDates(c, LibraryDatesSeed(dateAdded: day(3), lastOpened: day(3), lastUpdated: day(2), lastUpdatedChapters: day(2), lastChapter: day(1), lastRead: day(6)))
    }

    @Test(arguments: repositoryFixtures)
    func anEmptyLibraryIsEmpty(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        // a manga stored but not in the library, and an entry without a manga, count as nothing
        await store.seed.setManga(a, MangaSeed())
        await store.seed.addLibraryEntryWithoutManga()
        let result = try await page(store, filters: [filter(.downloaded)])
        #expect(result == LibraryPage(pinned: [], manga: [], sourceKeys: [], isEmpty: true, unappliedFilters: []))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func eachEntryCarriesItsManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        let result = try await page(store)
        #expect(result.isEmpty == false)
        #expect(result.pinned.isEmpty)
        #expect(keys(result.manga) == ["a", "b", "c"])
        #expect(result.sourceKeys == ["contract.source", "contract.other"])
        #expect(result.unappliedFilters.isEmpty)
        let alpha = try #require(result.manga.first)
        #expect(alpha == MangaInfo(
            id: a,
            coverUrl: URL(string: "https://example.com/a.jpg"),
            title: "alpha",
            author: "Autora",
            url: URL(string: "https://example.com/a")
        ))
        #expect(result.manga[1].coverUrl == nil)
        await store.tearDown()
    }

    /// Each order, both ways (the direction is the real one: the screen turns the title order before asking).
    @Test(arguments: repositoryFixtures)
    func everyOrder(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        func order(_ sort: LibraryQuery.Sort, _ ascending: Bool) async throws -> [String] {
            keys(try await page(store, sort: sort, ascending: ascending).manga)
        }
        #expect(try await order(.title, true) == ["a", "b", "c"])
        #expect(try await order(.title, false) == ["c", "b", "a"])
        #expect(try await order(.lastRead, true) == ["b", "a", "c"])
        #expect(try await order(.lastRead, false) == ["c", "a", "b"])
        #expect(try await order(.lastOpened, true) == ["b", "c", "a"])
        #expect(try await order(.lastOpened, false) == ["a", "c", "b"])
        #expect(try await order(.lastUpdated, true) == ["b", "c", "a"])
        #expect(try await order(.lastUpdated, false) == ["a", "c", "b"])
        #expect(try await order(.dateAdded, true) == ["a", "b", "c"])
        #expect(try await order(.dateAdded, false) == ["c", "b", "a"])
        // no last chapter goes first going up and last going down
        #expect(try await order(.lastChapter, true) == ["b", "c", "a"])
        #expect(try await order(.lastChapter, false) == ["a", "c", "b"])
        // by the number of stored chapters (3, 1, 0)
        #expect(try await order(.totalChapters, true) == ["c", "b", "a"])
        #expect(try await order(.totalChapters, false) == ["a", "b", "c"])
        // not ordered here: the screen orders by its unread counts
        #expect(Set(try await order(.unreadChapters, true)) == ["a", "b", "c"])
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func everyFilter(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        // started: any history row of the manga, linked or not, read or not
        #expect(try await shown(store, [filter(.started)]) == ["a", "c"])
        #expect(try await shown(store, [filter(.started, exclude: true)]) == ["b"])
        #expect(try await shown(store, [filter(.tracking)]) == ["a"])
        #expect(try await shown(store, [filter(.tracking, exclude: true)]) == ["b", "c"])
        #expect(try await shown(store, [filter(.completed)]) == ["a"])
        #expect(try await shown(store, [filter(.completed, exclude: true)]) == ["b", "c"])
        // sources: the included ones are OR; a filter without value does nothing
        #expect(try await shown(store, [filter(.source, "contract.other")]) == ["b"])
        #expect(try await shown(store, [filter(.source, "contract.other"), filter(.source, "contract.third")]) == ["b"])
        #expect(try await shown(store, [filter(.source, "contract.source", exclude: true)]) == ["b"])
        #expect(try await shown(store, [filter(.source)]) == ["a", "b", "c"])
        // content rating: the included ones are OR
        #expect(try await shown(store, [filter(.contentRating, MangaContentRating.nsfw.stringValue)]) == ["b"])
        #expect(try await shown(store, [
            filter(.contentRating, MangaContentRating.nsfw.stringValue), filter(.contentRating, MangaContentRating.suggestive.stringValue)
        ]) == ["b", "c"])
        #expect(try await shown(store, [filter(.contentRating, MangaContentRating.safe.stringValue, exclude: true)]) == ["b", "c"])
        #expect(try await shown(store, [filter(.contentRating, "nada")]) == ["a", "b", "c"])
        // categories: the included ones are OR, an excluded one leaves out any manga that has it
        #expect(try await shown(store, [filter(.category, "X")]) == ["a", "b"])
        #expect(try await shown(store, [filter(.category, "Y"), filter(.category, "Z")]) == ["b"])
        #expect(try await shown(store, [filter(.category, "X", exclude: true)]) == ["c"])
        #expect(try await shown(store, [filter(.category, "Y", exclude: true)]) == ["a", "c"])
        // together: all of them
        #expect(try await shown(store, [filter(.started), filter(.category, "X")]) == ["a"])
        #expect(try await shown(store, [filter(.started, exclude: true), filter(.completed)]) == [])
        await store.tearDown()
    }

    /// Downloads and unread counts are the screen's: not applied, and given back once per manga that reached them.
    @Test(arguments: repositoryFixtures)
    func whatTheScreenAppliesComesBack(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        let result = try await page(store, filters: [filter(.downloaded), filter(.hasUnread, exclude: true)])
        #expect(keys(result.manga) == ["a", "b", "c"])
        #expect(result.unappliedFilters == Array(repeating: [filter(.downloaded), filter(.hasUnread, exclude: true)], count: 3).flatMap { $0 })
        // a manga left out by an earlier filter does not reach them
        let after = try await page(store, filters: [filter(.tracking), filter(.downloaded)])
        #expect(keys(after.manga) == ["a"])
        #expect(after.unappliedFilters == [filter(.downloaded)])
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func scopes(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        #expect(keys(try await page(store, .category("X")).manga) == ["a", "b"])
        #expect(keys(try await page(store, .category("Y")).manga) == ["b"])
        // «uncategorized»: no category at all
        #expect(keys(try await page(store, .uncategorized).manga) == ["c"])
        let nothing = try await page(store, .category("Nope"))
        #expect(nothing.manga.isEmpty)
        #expect(nothing.isEmpty)
        #expect(nothing.sourceKeys.isEmpty)
        // filtered out is not empty; the sources are those of the whole scope
        let filteredOut = try await page(store, filters: [filter(.source, "contract.nada")])
        #expect(filteredOut.manga.isEmpty)
        #expect(!filteredOut.isEmpty)
        #expect(filteredOut.sourceKeys == ["contract.source", "contract.other"])
        let inY = try await page(store, .category("Y"), filters: [filter(.source, "contract.source")])
        #expect(inY.manga.isEmpty)
        #expect(inY.sourceKeys == ["contract.other"])
        await store.tearDown()
    }

    /// Pinned: chapters updated after it was last opened (strictly after).
    @Test(arguments: repositoryFixtures)
    func thePinOfUpdatedChapters(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        let pinned = try await page(store, pin: true)
        #expect(keys(pinned.pinned) == ["a"])
        #expect(keys(pinned.manga) == ["b", "c"])
        let byDate = try await page(store, sort: .dateAdded, ascending: false, filters: [filter(.completed, exclude: true)], pin: true)
        #expect(byDate.pinned.isEmpty)
        #expect(keys(byDate.manga) == ["c", "b"])
        await store.tearDown()
    }

    /// The same manga stored twice, both in the library: shown once.
    @Test(arguments: repositoryFixtures)
    func aRepeatedMangaIsShownOnce(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedLibrary(store)
        await store.seed.addDuplicateLibraryEntry(a)
        await store.seed.addLibraryEntryWithoutManga()
        for sort in LibraryQuery.Sort.allCases {
            let result = try await page(store, sort: sort)
            #expect(keys(result.manga).sorted() == ["a", "b", "c"], "\(sort)")
        }
        await store.tearDown()
    }
}
