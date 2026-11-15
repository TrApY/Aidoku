//
//  CategoryContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L2: the contract of CategoryRepository, against every fixture (each test on a store of its own).
//  Most of it CHARACTERIZES what the app does today (spec §1.5 nº 13-14), odd parts included: they are fixed as
//  they are, not fixed.
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct CategoryContractTests {
    private let m1 = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    private let m2 = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")
    /// the same manga key under another source is another manga
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")
    /// not in the library
    private let outside = MangaIdentifier(sourceKey: "contract.source", mangaKey: "fuera")

    private let filtersA = [
        LibraryFilter(type: .downloaded, value: nil, exclude: false),
        LibraryFilter(type: .source, value: "contract.source", exclude: true)
    ]
    private let filtersB = [LibraryFilter(type: .category, value: "ñ漢字🙂", exclude: false)]

    /// The categories A, B, C and then the filter groups G1, G2, created in that order.
    private func seeded(_ fixture: any RepositoryFixture) async throws -> FixtureStore {
        let store = try await fixture.make()
        let categories = store.repos.categories
        for title in ["A", "B", "C"] {
            #expect(await categories.create(title: title))
        }
        #expect(await categories.createFilterGroup(title: "G1", filters: filtersA))
        #expect(await categories.createFilterGroup(title: "G2", filters: filtersB))
        return store
    }

    private func sorted(_ titles: [String]) -> [String] { titles.sorted() }

    @Test(arguments: repositoryFixtures)
    func anEmptyStoreHasNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let categories = store.repos.categories
        #expect(await categories.titles(includeFilterGroups: false).isEmpty)
        #expect(await categories.titles(includeFilterGroups: true).isEmpty)
        #expect(await categories.filterGroupTitles().isEmpty)
        #expect(await categories.filterGroups().isEmpty)
        #expect(await categories.filterGroup(title: "G1") == nil)
        #expect(await categories.categories(of: m1).isEmpty)
        #expect(await !categories.contains(title: "A"))
        await store.tearDown()
    }

    /// Each kind is appended after the last one of its kind (`sort` = last `sort` of the same kind + 1), and the
    /// groups always go after the categories.
    @Test(arguments: repositoryFixtures)
    func eachKindIsAppendedAndTheGroupsGoLast(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        #expect(await categories.titles(includeFilterGroups: false) == ["A", "B", "C"])
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "B", "C", "G1", "G2"])
        #expect(await categories.filterGroupTitles() == ["G1", "G2"])
        #expect(await categories.filterGroups().map(\.title) == ["G1", "G2"])
        #expect(await categories.filterGroups().map(\.filters) == [filtersA, filtersB])
        #expect(await categories.filterGroup(title: "G2")?.filters == filtersB)
        #expect(await categories.filterGroup(title: "A") == nil) // a category has no filters
        #expect(await categories.contains(title: "A"))
        #expect(await categories.contains(title: "G2"))
        #expect(await !categories.contains(title: "a")) // titles are exact

        #expect(await categories.create(title: "ñ漢字🙂"))
        #expect(await categories.createFilterGroup(title: "G3", filters: []))
        #expect(await categories.create(title: "D"))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "B", "C", "ñ漢字🙂", "D", "G1", "G2", "G3"])
        #expect(await categories.filterGroup(title: "G3")?.filters == [])
        await store.tearDown()
    }

    /// `create` does not check the title (the screens do): creating twice gives two, and removing takes one.
    @Test(arguments: repositoryFixtures)
    func createDoesNotDeduplicate(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let categories = store.repos.categories
        #expect(await categories.create(title: "A"))
        #expect(await categories.create(title: "A"))
        #expect(await categories.titles(includeFilterGroups: false) == ["A", "A"])
        #expect(await categories.remove(title: "A"))
        #expect(await categories.titles(includeFilterGroups: false) == ["A"])
        await store.tearDown()
    }

    /// Removing renumbers the order of both kinds; the groups stay after the categories, and new ones of each kind
    /// still go last.
    @Test(arguments: repositoryFixtures)
    func removingRenumbers(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        #expect(await categories.remove(title: "B"))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "C", "G1", "G2"])
        #expect(await categories.remove(title: "nadie")) // nothing to remove: saves well
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "C", "G1", "G2"])
        #expect(await categories.create(title: "D"))
        #expect(await categories.createFilterGroup(title: "G3", filters: filtersA))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "C", "D", "G1", "G2", "G3"])
        #expect(await categories.remove(title: "G1"))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "C", "D", "G2", "G3"])
        #expect(await categories.filterGroups().map(\.title) == ["G2", "G3"])
        await store.tearDown()
    }

    /// Settings → Categories: dragging a category. `position` is a position of the order of both kinds.
    @Test(arguments: repositoryFixtures)
    func movingACategory(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        #expect(await categories.move(["A"], to: 2))
        #expect(await categories.titles(includeFilterGroups: true) == ["B", "C", "A", "G1", "G2"])
        #expect(await categories.move(["A"], to: 0))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "B", "C", "G1", "G2"])
        // nothing to do: same place, unknown title, out of range
        #expect(await categories.move(["B"], to: 1))
        #expect(await categories.move(["nadie"], to: 0))
        #expect(await categories.move(["A"], to: 99))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "B", "C", "G1", "G2"])
        await store.tearDown()
    }

    /// ODD (kept as it is): moving several at once moves each title in turn to the same position, from the last
    /// one; dragging A and B below C (what the screen sends: [B, A] to 1) gives B, A, C and not C, A, B.
    @Test(arguments: repositoryFixtures)
    func movingSeveralCategoriesMovesEachInTurn(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        #expect(await categories.move(["B", "A"], to: 1))
        #expect(await categories.titles(includeFilterGroups: false) == ["B", "A", "C"])
        await store.tearDown()
    }

    /// With only filter groups, dragging a group moves it.
    @Test(arguments: repositoryFixtures)
    func movingAGroupWithoutCategories(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let categories = store.repos.categories
        for title in ["G1", "G2", "G3"] {
            #expect(await categories.createFilterGroup(title: title, filters: filtersA))
        }
        #expect(await categories.move(["G1"], to: 2))
        #expect(await categories.filterGroupTitles() == ["G2", "G3", "G1"])
        await store.tearDown()
    }

    /// ODD, spec §1.5 nº 13 (kept as it is): a new group's `sort` counts among the groups, but moving compares it
    /// with positions of the order of both kinds, and Settings → Filter groups sends a position among the groups.
    /// With categories present, dragging the first group below the second one swaps the first two CATEGORIES and
    /// leaves the groups as they were; after that renumbering, dragging the second group to the top does move it.
    @Test(arguments: repositoryFixtures)
    func movingAGroupWithCategoriesPresent(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        #expect(await categories.move(["G1"], to: 1))
        #expect(await categories.titles(includeFilterGroups: true) == ["B", "A", "C", "G1", "G2"])
        #expect(await categories.move(["G2"], to: 0))
        #expect(await categories.titles(includeFilterGroups: true) == ["B", "A", "C", "G2", "G1"])
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func renaming(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        // keeps its place; gives the category titles (no groups)
        #expect(await categories.rename("A", to: "ñ漢字🙂") == ["ñ漢字🙂", "B", "C"])
        // not renamed: the new title exists (a category, a group, itself), or there is no such title
        #expect(await categories.rename("B", to: "C") == nil)
        #expect(await categories.rename("B", to: "G1") == nil)
        #expect(await categories.rename("B", to: "B") == nil)
        #expect(await categories.rename("nadie", to: "Y") == nil)
        #expect(await categories.titles(includeFilterGroups: true) == ["ñ漢字🙂", "B", "C", "G1", "G2"])
        // a group is renamed the same way and keeps its filters
        #expect(await categories.rename("G1", to: "H") == ["ñ漢字🙂", "B", "C"])
        #expect(await categories.filterGroupTitles() == ["H", "G2"])
        #expect(await categories.filterGroup(title: "H")?.filters == filtersA)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func updatingAFilterGroup(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        let categories = store.repos.categories
        #expect(await categories.updateFilterGroup(title: "G1", newTitle: "G9", filters: filtersB))
        #expect(await categories.filterGroupTitles() == ["G9", "G2"])
        #expect(await categories.filterGroup(title: "G9")?.filters == filtersB)
        #expect(await categories.filterGroup(title: "G1") == nil)
        #expect(await categories.updateFilterGroup(title: "G9", newTitle: "G9", filters: [])) // same title
        #expect(await categories.filterGroup(title: "G9")?.filters == [])
        // no such group: a successful save that creates nothing
        #expect(await categories.updateFilterGroup(title: "nadie", newTitle: "X", filters: filtersA))
        #expect(await categories.titles(includeFilterGroups: true) == ["A", "B", "C", "G9", "G2"])
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func theCategoriesOfAManga(fixture: any RepositoryFixture) async throws {
        let store = try await seeded(fixture)
        await store.addToLibrary([m1, m2, sameKeyOtherSource])
        let categories = store.repos.categories
        #expect(await categories.assign([m1, m2, outside], add: ["A", "B", "nadie"]))
        #expect(await categories.assign([m1], add: ["A"])) // again: nothing changes
        #expect(sorted(await categories.categories(of: m1)) == ["A", "B"])
        #expect(sorted(await categories.categories(of: m2)) == ["A", "B"])
        #expect(await categories.categories(of: sameKeyOtherSource).isEmpty)
        #expect(await categories.categories(of: outside).isEmpty)

        #expect(await categories.set(["C", "nadie"], for: m1))
        #expect(await categories.categories(of: m1) == ["C"])
        #expect(sorted(await categories.categories(of: m2)) == ["A", "B"])
        #expect(await categories.set(["C"], for: outside)) // not in the library: skipped
        #expect(await categories.categories(of: outside).isEmpty)

        #expect(await categories.remove(["A", "nadie"], from: m2))
        #expect(await categories.categories(of: m2) == ["B"])
        #expect(await categories.remove(["A"], from: outside))
        // removing a category takes it off its manga
        #expect(await categories.remove(title: "B"))
        #expect(await categories.categories(of: m2).isEmpty)
        #expect(await categories.set([], for: m1))
        #expect(await categories.categories(of: m1).isEmpty)
        await store.tearDown()
    }
}
