//
//  DownloadedEntryContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-8): the downloads list, for a downloaded manga without ComicInfo, looks for the stored
//  manga its directory stands for, in one read: the manga with that key, or else the first one of the source whose
//  key gives that directory name; and whether it is in the library.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct DownloadedEntryContractTests {
    private let source = "contract.source"

    @Test(arguments: repositoryFixtures)
    func theExactKeyFirst(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let manga = MangaIdentifier(sourceKey: source, mangaKey: "m1")
        await store.addToLibrary([manga])
        await store.seed.setManga(manga, MangaSeed(cover: "https://example.com/m1.jpg", title: "Uno"))
        // the same key in another source does not count
        await store.seed.setManga(MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1"), MangaSeed(title: "Otro"))
        let entry = await store.repos.library.downloadedEntry(sourceKey: source, directoryName: "m1")
        #expect(entry == DownloadedEntryInfo(title: "Uno", cover: "https://example.com/m1.jpg", isInLibrary: true, mangaKey: "m1"))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func aKeyThatOnlyGivesTheDirectoryName(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let key = "uno:dos/tres"
        let directory = key.directoryName
        try #require(directory != key)
        let manga = MangaIdentifier(sourceKey: source, mangaKey: key)
        await store.addToLibrary([manga])
        await store.seed.setManga(manga, MangaSeed(title: "Saneado"))
        // in another source, the same key is not looked at
        let entry = await store.repos.library.downloadedEntry(sourceKey: "contract.other", directoryName: directory)
        #expect(entry == DownloadedEntryInfo(title: nil, cover: nil, isInLibrary: false, mangaKey: directory))
        let found = await store.repos.library.downloadedEntry(sourceKey: source, directoryName: directory)
        #expect(found == DownloadedEntryInfo(title: "Saneado", cover: nil, isInLibrary: true, mangaKey: key))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func aMangaOutsideTheLibrary(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await store.seed.setManga(MangaIdentifier(sourceKey: source, mangaKey: "m2"), MangaSeed(title: "Fuera"))
        let entry = await store.repos.library.downloadedEntry(sourceKey: source, directoryName: "m2")
        #expect(entry == DownloadedEntryInfo(title: "Fuera", cover: nil, isInLibrary: false, mangaKey: "m2"))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func noStoredManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let entry = await store.repos.library.downloadedEntry(sourceKey: source, directoryName: "sin-manga")
        #expect(entry == DownloadedEntryInfo(title: nil, cover: nil, isInLibrary: false, mangaKey: "sin-manga"))
        await store.tearDown()
    }
}
