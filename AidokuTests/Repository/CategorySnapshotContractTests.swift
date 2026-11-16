//
//  CategorySnapshotContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L6: Settings, the library, the filter group editor and the category picker read the categories and
//  the filter groups together, in one read: the snapshot is what each of those reads gives.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct CategorySnapshotContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    private let other = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")

    @Test(arguments: repositoryFixtures)
    func theSnapshotIsWhatEachReadGives(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repo = store.repos.categories
        #expect(await repo.snapshot(of: manga, filterGroup: "G") == CategorySnapshot())
        await repo.create(title: "B")
        await repo.create(title: "A")
        await repo.createFilterGroup(title: "G", filters: [])
        await store.addToLibrary([manga])
        await repo.assign([manga], add: ["A"])
        let all = await repo.snapshot(of: manga, filterGroup: "G")
        #expect(all.titles == (await repo.titles(includeFilterGroups: false)))
        #expect(all.titles.count == 2)
        #expect(all.titlesAndGroups == (await repo.titles(includeFilterGroups: true)))
        #expect(all.titlesAndGroups.last == "G")
        #expect(all.filterGroups == (await repo.filterGroups()))
        #expect(all.filterGroups.map(\.title) == ["G"])
        #expect(all.categoriesOfManga == (await repo.categories(of: manga)))
        #expect(all.categoriesOfManga == ["A"])
        #expect(all.filterGroup == (await repo.filterGroup(title: "G")))
        #expect(all.filterGroup?.title == "G")
        // nothing asked
        let plain = await repo.snapshot(of: nil, filterGroup: nil)
        #expect(plain.titles == all.titles)
        #expect(plain.titlesAndGroups == all.titlesAndGroups)
        #expect(plain.filterGroups == all.filterGroups)
        #expect(plain.categoriesOfManga.isEmpty)
        #expect(plain.filterGroup == nil)
        // a manga not in the library, a group that does not exist, a normal category asked as a group
        let notInLibrary = await repo.snapshot(of: other, filterGroup: "X")
        #expect(notInLibrary.categoriesOfManga.isEmpty)
        #expect(notInLibrary.filterGroup == nil)
        #expect(await repo.snapshot(of: nil, filterGroup: "A").filterGroup == (await repo.filterGroup(title: "A")))
        await store.tearDown()
    }
}
