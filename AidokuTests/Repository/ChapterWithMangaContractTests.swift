//
//  ChapterWithMangaContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L6: the history list and the vocabulary entries read a chapter and its manga in one read.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct ChapterWithMangaContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    private let other = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")

    private func id(_ key: String, _ manga: MangaIdentifier? = nil) -> ChapterIdentifier {
        let manga = manga ?? self.manga
        return ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    @Test(arguments: repositoryFixtures)
    func theChapterComesWithItsManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let chapters = store.repos.chapters
        await store.seed.addChapters([AidokuRunner.Chapter(key: "c1", title: "Uno", chapterNumber: 1)], to: manga)
        await store.seed.setManga(manga, MangaSeed(cover: "https://example.com/m1.jpg"))
        await store.seed.setManga(other, MangaSeed())
        let both = await chapters.chapterWithManga(id("c1"))
        #expect(both.manga?.key == "m1")
        #expect(both.manga?.cover == "https://example.com/m1.jpg")
        #expect(both.chapter?.key == "c1")
        #expect(both.chapter?.title == "Uno")
        // the same as reading them apart
        #expect(both.manga == (await store.repos.manga.manga(manga)))
        #expect(both.chapter == (await chapters.chapter(id("c1"))))
        // the manga without that chapter, another manga, and nothing stored
        let noChapter = await chapters.chapterWithManga(id("c9"))
        #expect(noChapter.manga?.key == "m1")
        #expect(noChapter.chapter == nil)
        let otherManga = await chapters.chapterWithManga(id("c1", other))
        #expect(otherManga.manga?.key == "m2")
        #expect(otherManga.chapter == nil)
        #expect(await chapters.chapterWithManga(id("c1", sameKeyOtherSource)) == ChapterWithManga(manga: nil, chapter: nil))
        await store.tearDown()
    }
}
