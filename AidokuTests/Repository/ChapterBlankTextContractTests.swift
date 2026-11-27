//
//  ChapterBlankTextContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L6: download ahead, the downloads, the next chapter and the trackers read the stored chapters through
//  the old `Chapter` before the repositories, and that turned an empty title or scanlator into nil.
//  `chaptersBlankAsNil(of:)` gives them the same again; `chapters(of:)` keeps what is stored.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct ChapterBlankTextContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")

    @Test(arguments: repositoryFixtures)
    func blankTextComesBackAsNil(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let chapters = store.repos.chapters
        await store.seed.addChapters([
            AidokuRunner.Chapter(key: "c1", title: "", chapterNumber: 1, scanlators: [""], language: "es"),
            AidokuRunner.Chapter(key: "c2", title: "Dos", chapterNumber: 2, scanlators: ["A", "B"], language: "es", locked: true),
            AidokuRunner.Chapter(key: "c3", chapterNumber: 3)
        ], to: manga)
        // chapters(of:) keeps what is stored
        let stored = await chapters.chapters(of: manga)
        try #require(stored.count == 3)
        #expect(stored[0].title == "")
        #expect(stored[0].scanlators == [""])
        // as before: nil
        let before = await chapters.chaptersBlankAsNil(of: manga)
        try #require(before.count == 3)
        #expect(before.map(\.key) == ["c1", "c2", "c3"])
        #expect(before[0].title == nil)
        #expect(before[0].scanlators == nil)
        #expect(before[1].title == "Dos")
        #expect(before[1].scanlators == ["A", "B"])
        #expect(before[1].locked)
        #expect(before[2].title == nil)
        #expect(before[2].scanlators == nil)
        // the rest as chapters(of:)
        #expect(before.map(\.chapterNumber) == stored.map(\.chapterNumber))
        #expect(before.map(\.language) == stored.map(\.language))
        #expect(before.map(\.url) == stored.map(\.url))
        #expect(before.map(\.locked) == stored.map(\.locked))
        #expect(await chapters.chaptersBlankAsNil(of: MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")).isEmpty)
        await store.tearDown()
    }

    /// An empty stored url (bajo nº 19) comes back as nil from both reads.
    @Test(arguments: repositoryFixtures)
    func aBlankURLComesBackAsNil(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let chapters = store.repos.chapters
        await store.seed.addChapters([
            AidokuRunner.Chapter(key: "c1", title: "", chapterNumber: 1),
            AidokuRunner.Chapter(key: "c2", chapterNumber: 2, url: URL(string: "https://example.com/c2"))
        ], to: manga)
        await store.seed.setChapterURL(ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: "c1"), "")
        let stored = await chapters.chapters(of: manga)
        try #require(stored.count == 2)
        #expect(stored[0].url == nil)
        #expect(stored[1].url == URL(string: "https://example.com/c2"))
        let before = await chapters.chaptersBlankAsNil(of: manga)
        try #require(before.count == 2)
        #expect(before[0].url == nil)
        #expect(before[1].url == URL(string: "https://example.com/c2"))
        await store.tearDown()
    }
}
