//
//  ChapterSortMemoryTests.swift
//  AidokuTests
//
//  SUWA-12 G2: each manga remembers its chapter order; the last one chosen is the default for the rest.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct ChapterSortMemoryTests {
    private let mangaA = MangaIdentifier(sourceKey: "ordentest", mangaKey: "a")
    private let mangaB = MangaIdentifier(sourceKey: "ordentest", mangaKey: "b")
    private let ascending = ChapterSortChoice(option: ChapterSortOption.sourceOrder.rawValue, ascending: true)
    private let byDate = ChapterSortChoice(option: ChapterSortOption.uploadDate.rawValue, ascending: false)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ordentest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func leavingAndComingBackKeepsTheOrder() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(ascending, for: mangaA, defaults: defaults)
            #expect(ChapterSortMemory.load(for: mangaA, flags: 0, defaults: defaults) == ascending)
        }
    }

    @Test func aNewMangaTakesTheLastOrderChosen() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(byDate, for: mangaA, defaults: defaults)
            #expect(ChapterSortMemory.load(for: mangaB, flags: 0, defaults: defaults) == byDate)
        }
    }

    @Test func aMangaWithItsOwnOrderKeepsIt() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(ascending, for: mangaA, defaults: defaults)
            ChapterSortMemory.record(byDate, for: mangaB, defaults: defaults)
            #expect(ChapterSortMemory.load(for: mangaA, flags: 0, defaults: defaults) == ascending)
        }
    }

    @Test func theOrderStoredInTheLibraryEntryCounts() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(byDate, for: mangaB, defaults: defaults) // the default now
            #expect(ChapterSortMemory.load(for: mangaA, flags: ChapterFlagMask.sortAscending, defaults: defaults) == ascending)
        }
    }

    @MainActor
    @Test func choosingAnOrderInTheMangaPageRemembersIt() throws {
        let manga = AidokuRunner.Manga(sourceKey: "ordentest", key: "pagina", title: "Orden")
        let key = ChapterSortMemory.key(manga.identifier)
        let savedDefault = UserDefaults.standard.data(forKey: ChapterSortMemory.defaultKey)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.set(savedDefault, forKey: ChapterSortMemory.defaultKey)
        }
        let model = MangaView.ViewModel(source: nil, manga: manga)
        model.chapterSortAscending = true
        #expect(ChapterSortMemory.load(for: manga.identifier, flags: 0) == ascending)
    }
}
