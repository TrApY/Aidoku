//
//  LibraryResetContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-7): Settings › Advanced › Reset empties the data in two parts with the history in
//  between (spec §1.3 nº 18), as it did. After the three steps, in the screen's order, nothing is left.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibraryResetContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "a")
    private let b = MangaIdentifier(sourceKey: "contract.other", mangaKey: "b")
    /// stored, not in the library
    private let out = MangaIdentifier(sourceKey: "contract.source", mangaKey: "fuera")

    private func id(_ key: String, _ manga: MangaIdentifier) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    @Test(arguments: repositoryFixtures)
    func theThreeStepsLeaveNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await store.addToLibrary([a, b])
        await store.seed.addChapters([.init(key: "a1"), .init(key: "a2")], to: a)
        await store.seed.addChapters([.init(key: "x1")], to: out)
        await store.seed.addHistory(HistorySeed(chapter: id("a1", a), progress: 2))
        await store.seed.addHistory(HistorySeed(chapter: id("x1", out), progress: 1))
        await repos.tracks.add(TrackItem(id: "t1", trackerId: "contract.tracker", mangaId: a, title: nil, chapterOffset: 0))
        await repos.categories.create(title: "X")
        await repos.categories.createFilterGroup(title: "G", filters: [])
        await repos.categories.assign([a], add: ["X"])
        #expect(await repos.library.contains(a))

        // as Settings does it
        await repos.library.clearLibraryAndManga()
        await repos.history.clear(excludingLibrary: false)
        await repos.library.clearChaptersCategoriesAndTracks()

        for manga in [a, b, out] {
            #expect(await !repos.library.contains(manga))
            #expect(await !repos.manga.contains(manga))
            #expect(await repos.chapters.chapters(of: manga).isEmpty)
            #expect(await !repos.history.hasHistory(of: manga))
            #expect(await repos.tracks.items(of: manga).isEmpty)
        }
        #expect(await repos.library.entries(category: nil).isEmpty)
        #expect(await repos.categories.titles(includeFilterGroups: true).isEmpty)
        #expect(await store.seed.historyRows(of: id("a1", a)) == 0)
        #expect(await store.seed.historyRows(of: id("x1", out)) == 0)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func eachPartClearsItsOwn(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await store.addToLibrary([a])
        await store.seed.addChapters([.init(key: "a1")], to: a)
        await repos.tracks.add(TrackItem(id: "t1", trackerId: "contract.tracker", mangaId: a, title: nil, chapterOffset: 0))
        await repos.categories.create(title: "X")
        // the first part: the library and the manga
        await repos.library.clearLibraryAndManga()
        #expect(await !repos.library.contains(a))
        #expect(await !repos.manga.contains(a))
        #expect(await repos.categories.titles(includeFilterGroups: true) == ["X"])
        #expect(await repos.tracks.items(of: a).count == 1)
        // the second: the chapters, the categories and the tracks
        await repos.library.clearChaptersCategoriesAndTracks()
        #expect(await repos.chapters.chapters(of: a).isEmpty)
        #expect(await repos.categories.titles(includeFilterGroups: true).isEmpty)
        #expect(await repos.tracks.items(of: a).isEmpty)
        await store.tearDown()
    }
}
