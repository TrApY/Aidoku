//
//  CategoryMoveConflictContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-9, bajo nº 4): a drag in Categories or in Filter groups (`categories.move`) used to be
//  saved in the view context, whose merge policy keeps the drag when another write (a second drag, an iCloud
//  import) changed the same categories at the same time. The repository's move keeps it too. Both screens call
//  this same method.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct CategoryMoveConflictContractTests {
    @Test(arguments: repositoryFixtures)
    func aMoveKeepsItsOrderAgainstAWriteAtTheSameTime(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let categories = store.repos.categories
        for title in ["A", "B", "C"] {
            await categories.create(title: title)
        }
        #expect(await categories.titles(includeFilterGroups: false) == ["A", "B", "C"])
        // another write moves C to the top while this move is being saved
        await store.seed.moveCategoryBeforeNextSave("C", to: 0)
        #expect(await categories.move(["A"], to: 2))
        #expect(await categories.titles(includeFilterGroups: false) == ["B", "C", "A"])
        await store.tearDown()
    }
}
