//
//  ChapterSortSyncTests.swift
//  AidokuTests
//
//  SUWA-12 H5: in the library the order chosen lives in its flags (synced by iCloud), not on the device;
//  «the source's order, descending» chosen on purpose is told apart from «never chosen».
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct ChapterSortSyncTests {
    private let mangaA = MangaIdentifier(sourceKey: "ordensync", mangaKey: "a")
    private let mangaB = MangaIdentifier(sourceKey: "ordensync", mangaKey: "b")
    private let ascending = ChapterSortChoice(option: ChapterSortOption.sourceOrder.rawValue, ascending: true)
    private let byDate = ChapterSortChoice(option: ChapterSortOption.uploadDate.rawValue, ascending: false)

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ordensync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    /// The iPad chose «by date» (the flags come by iCloud); the iPhone had chosen ascending before.
    @Test func aChangeOnTheOtherDeviceWinsOverTheOrderHere() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(ascending, for: mangaA, defaults: defaults)
            let flags = ChapterSortMemory.flags(byDate, into: 0)
            #expect(ChapterSortMemory.load(for: mangaA, flags: flags, defaults: defaults) == byDate)
        }
    }

    @Test func theSourceOrderDescendingChosenDoesNotInherit() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(byDate, for: mangaB, defaults: defaults) // the last one chosen
            let flags = ChapterSortMemory.flags(.initial, into: 0)
            #expect(flags != 0)
            #expect(ChapterSortMemory.load(for: mangaA, flags: flags, defaults: defaults) == .initial)
        }
    }

    @Test func choosingInTheLibraryGoesToTheFlagsNotTheDevice() throws {
        try withDefaults { defaults in
            ChapterSortMemory.record(byDate, for: mangaA, defaults: defaults) // before, out of the library
            ChapterSortMemory.record(ascending, for: mangaA, inLibrary: true, defaults: defaults)
            #expect(ChapterSortMemory.local(for: mangaA, defaults: defaults) == nil)
            #expect(ChapterSortMemory.load(for: mangaB, flags: 0, defaults: defaults) == ascending) // still the default
        }
    }

    /// Chosen out of the library, then added: the order goes to the library flags and leaves the device.
    @Test func addingToTheLibraryTakesTheOrderOfTheDevice() async throws {
        let manga = AidokuRunner.Manga(sourceKey: "ordensync", key: "biblioteca", title: "Orden")
        let id = manga.identifier
        let savedDefault = UserDefaults.standard.data(forKey: ChapterSortMemory.defaultKey)
        defer {
            ChapterSortMemory.forgetLocal(id)
            UserDefaults.standard.set(savedDefault, forKey: ChapterSortMemory.defaultKey)
        }
        ChapterSortMemory.record(ascending, for: id)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: [.init(key: "c1", chapterNumber: 1)], bindTrackers: false)
        let flags = await DataRepositories.shared.manga.chapterFilters(id).flags
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeManga(mangaId: id, context: context)
            try? context.save()
        }
        #expect(ChapterSortMemory.chosen(inFlags: flags) == ascending)
        #expect(ChapterSortMemory.local(for: id) == nil)
    }
}
