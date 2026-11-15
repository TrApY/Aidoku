//
//  LibraryContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L3: the membership part of LibraryRepository, against every fixture (each test on a store of its own).
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibraryContractTests {
    private let m1 = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    private let m2 = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")
    /// the same manga key under another source is another manga
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")
    private let unicode = MangaIdentifier(sourceKey: "contract.source", mangaKey: "ñ漢字🙂 / ?&")

    @Test(arguments: repositoryFixtures)
    func anEmptyLibraryHasNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let library = store.repos.library
        #expect(await !library.contains(m1))
        #expect(await library.contained(in: []).isEmpty)
        #expect(await library.contained(in: [m1, m2]).isEmpty)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func addingAndRemoving(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let library = store.repos.library
        await store.addToLibrary([m1, unicode])
        #expect(await library.contains(m1))
        #expect(await library.contains(unicode))
        #expect(await !library.contains(m2))
        #expect(await !library.contains(sameKeyOtherSource))
        #expect(await library.contained(in: [m1, m2, sameKeyOtherSource, unicode]) == [m1, unicode])

        await store.removeFromLibrary([m1])
        #expect(await !library.contains(m1))
        #expect(await library.contains(unicode))
        #expect(await library.contained(in: [m1, unicode]) == [unicode])
        await store.tearDown()
    }

    /// The other source's manga with the same key is in the library; this one is not.
    @Test(arguments: repositoryFixtures)
    func theSameKeyUnderAnotherSourceIsAnotherManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let library = store.repos.library
        await store.addToLibrary([sameKeyOtherSource])
        #expect(await !library.contains(m1))
        #expect(await library.contains(sameKeyOtherSource))
        #expect(await library.contained(in: [m1, sameKeyOtherSource]) == [sameKeyOtherSource])
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func repeatedIdsCountOnce(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let library = store.repos.library
        await store.addToLibrary([m1])
        #expect(await library.contained(in: [m1, m2, m1, m1, m2]) == [m1])
        await store.tearDown()
    }

    /// 200 ids (more than one internal batch), 2 of each 3 in the library, half of them also under another source.
    @Test(arguments: repositoryFixtures)
    func twoHundredIdsInOneCall(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let library = store.repos.library
        let ids = (0..<200).map { MangaIdentifier(sourceKey: "contract.source", mangaKey: "k\($0)") }
        let inLibrary = ids.enumerated().filter { $0.offset % 3 != 0 }.map(\.element)
        let others = (0..<200).filter { $0.isMultiple(of: 2) }.map { MangaIdentifier(sourceKey: "contract.other", mangaKey: "k\($0)") }
        await store.addToLibrary(inLibrary + others)
        #expect(await library.contained(in: ids) == Set(inLibrary))
        #expect(await library.contained(in: ids + others + ids) == Set(inLibrary + others))
        #expect(await library.contains(ids[1]))
        #expect(await !library.contains(ids[0]))
        await store.tearDown()
    }
}
