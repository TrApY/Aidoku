//
//  RemapContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L11c (D-L11-7): a source that changed its ids. LibraryRepository.identifiersToRemap reads what the
//  source has to look up, and remapIdentifiers rewrites the keys of its manga in the library, its chapters and its
//  history in one save, against every fixture. Another source with the same manga key is not touched.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct RemapContractTests {
    private let key = "contract.\(UUID().uuidString)"
    private var source: String { "\(key).fuente" }
    private var other: String { "\(key).otra" }

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func chapter(_ sourceKey: String, _ mangaKey: String, _ chapterKey: String) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: sourceKey, mangaKey: mangaKey, chapterKey: chapterKey)
    }

    /// In both sources the manga «a» in the library with chapters c1 and c2 and a history row for c1; in the
    /// source, also the manga «b» not in the library with a history row for x1.
    private func seed(_ store: FixtureStore) async {
        let chapters = [AidokuRunner.Chapter(key: "c2", chapterNumber: 2), AidokuRunner.Chapter(key: "c1", chapterNumber: 1)]
        for sourceKey in [source, other] {
            await store.repos.library.add(AidokuRunner.Manga(sourceKey: sourceKey, key: "a", title: "A"), chapters: chapters, defaultCategory: nil, adoptChapterFlags: nil)
            await store.seed.addHistory(HistorySeed(chapter: chapter(sourceKey, "a", "c1"), progress: 3, total: 9, dateRead: day(1)))
        }
        await store.seed.addHistory(HistorySeed(chapter: chapter(source, "b", "x1"), total: 0, completed: true, dateRead: day(2), linked: false))
    }

    /// The source's manga in the library, its chapters and its history rows; not the other source's.
    @Test(arguments: repositoryFixtures)
    func whatTheSourceLooksUp(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seed(store)
        let read = await store.repos.library.identifiersToRemap(sourceKey: source)
        #expect(read.libraryMangaKeys == ["a"])
        #expect(Set(read.chapters.map { "\($0.mangaKey)/\($0.chapterKey)" }) == ["a/c1", "a/c2"])
        #expect(Set(read.historyMangaKeys) == ["a", "b"])
        #expect(read.historyMangaKeys.count == 2)
        #expect(Set(read.historyChapters.map { "\($0.mangaKey)/\($0.chapterKey)" }) == ["a/c1", "b/x1"])
        let none = await store.repos.library.identifiersToRemap(sourceKey: "\(key).nada")
        #expect(none.libraryMangaKeys.isEmpty && none.chapters.isEmpty && none.historyMangaKeys.isEmpty && none.historyChapters.isEmpty)
        await store.tearDown()
    }

    /// The source's keys are rewritten in the manga, the chapters and the history; keys without a new one stay;
    /// the other source, with the same manga key, is as it was.
    @Test(arguments: repositoryFixtures)
    func theSourcesKeysAreRewritten(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seed(store)
        let saved = await repos.library.remapIdentifiers(
            IdentifierRemap(sourceKey: source, mangaKeys: ["a": "a2", "b": "b2"], chapterKeys: ["c1": "c1n", "x1": "x1n"])
        )
        #expect(saved)
        let newA = MangaIdentifier(sourceKey: source, mangaKey: "a2")
        #expect(await repos.library.contains(newA))
        #expect(await !repos.manga.contains(MangaIdentifier(sourceKey: source, mangaKey: "a")))
        #expect(Set(await repos.chapters.chapters(of: newA).map { $0.key }) == ["c1n", "c2"])
        let c1 = try #require(await repos.history.record(of: chapter(source, "a2", "c1n")))
        #expect(c1.progress == 3 && c1.total == 9)
        #expect(await repos.history.record(of: chapter(source, "a", "c1")) == nil)
        #expect(try #require(await repos.history.record(of: chapter(source, "b2", "x1n"))).completed)
        // the other source
        let otherA = MangaIdentifier(sourceKey: other, mangaKey: "a")
        #expect(await repos.library.contains(otherA))
        #expect(Set(await repos.chapters.chapters(of: otherA).map { $0.key }) == ["c1", "c2"])
        #expect(try #require(await repos.history.record(of: chapter(other, "a", "c1"))).progress == 3)
        await store.tearDown()
    }

    /// Nothing to rewrite: nothing changes (and the save goes well).
    @Test(arguments: repositoryFixtures)
    func emptyMapsChangeNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seed(store)
        #expect(await repos.library.remapIdentifiers(IdentifierRemap(sourceKey: source, mangaKeys: [:], chapterKeys: [:])))
        let a = MangaIdentifier(sourceKey: source, mangaKey: "a")
        #expect(await repos.library.contains(a))
        #expect(Set(await repos.chapters.chapters(of: a).map { $0.key }) == ["c1", "c2"])
        #expect(try #require(await repos.history.record(of: chapter(source, "a", "c1"))).progress == 3)
        #expect(try #require(await repos.history.record(of: chapter(source, "b", "x1"))).completed)
        await store.tearDown()
    }

    /// A failed save: false, and nothing rewritten.
    @Test(arguments: repositoryFixtures)
    func aFailedSaveRewritesNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seed(store)
        let saved = await store.failingRepos.library.remapIdentifiers(
            IdentifierRemap(sourceKey: source, mangaKeys: ["a": "a2"], chapterKeys: ["c1": "c1n"])
        )
        #expect(!saved)
        #expect(await repos.library.contains(MangaIdentifier(sourceKey: source, mangaKey: "a")))
        #expect(await !repos.library.contains(MangaIdentifier(sourceKey: source, mangaKey: "a2")))
        #expect(try #require(await repos.history.record(of: chapter(source, "a", "c1"))).progress == 3)
        await store.tearDown()
    }
}
