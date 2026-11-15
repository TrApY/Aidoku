//
//  MangaSettingsMoveTests.swift
//  AidokuTests
//
//  SUWA-12 H6: migrating takes the order chosen too; removing from the library forgets the device's order
//  when the flags had it; the Suwayomi conversion moves the order key like the other per-manga ones.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct MangaSettingsMoveTests {
    private let ascending = ChapterSortChoice(option: ChapterSortOption.sourceOrder.rawValue, ascending: true)

    @Test func migratingTakesTheOrderAndTheReadingMode() throws {
        let suite = "mover.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = MangaIdentifier(sourceKey: "vieja", mangaKey: "1")
        let new = MangaIdentifier(sourceKey: "nueva", mangaKey: "9")
        ChapterSortMemory.record(ascending, for: old, defaults: defaults)
        defaults.set("webtoon", forKey: "Reader.readingMode.\(old)")
        MangaManager.moveMangaSettings(from: old, to: new, copy: false, defaults: defaults)
        #expect(ChapterSortMemory.local(for: new, defaults: defaults) == ascending)
        #expect(ChapterSortMemory.local(for: old, defaults: defaults) == nil)
        #expect(defaults.string(forKey: "Reader.readingMode.\(new)") == "webtoon")
        #expect(defaults.object(forKey: "Reader.readingMode.\(old)") == nil)
    }

    @Test func removingFromTheLibraryForgetsTheDeviceOrderWhenTheFlagsHadIt() async throws {
        let manga = AidokuRunner.Manga(sourceKey: "ordenquitar", key: "q1", title: "Quitar")
        let id = manga.identifier
        defer { ChapterSortMemory.forgetLocal(id) }
        let ascending = ascending
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(manga: manga, chapters: [.init(key: "c1", chapterNumber: 1)], context: context)
            CoreDataManager.shared.getManga(mangaId: id, context: context)?.chapterFlags = Int16(ChapterSortMemory.flags(ascending, into: 0))
            try? context.save()
        }
        ChapterSortMemory.record(ascending, for: id) // an old one of the device
        await MangaManager.shared.removeFromLibrary(mangaId: id)
        #expect(ChapterSortMemory.local(for: id) == nil)
    }

    /// `Manga.chapterSort.<parent>.<id>` counts as a per-manga setting (it moves to the server source with
    /// the manga, it doesn't leave its own pending one); the child's key and the default aren't the parent's.
    @Test func theConversionMovesTheOrderKeyLikeTheOthers() {
        #expect(SuwayomiSourceConversion.perMangaKey("Manga.chapterSort.suwayomi.suwa.101", parent: "suwayomi.suwa")?.prefix == "Manga.chapterSort")
        #expect(SuwayomiSourceConversion.perMangaKey("Manga.chapterSort.suwayomi.suwa.101", parent: "suwayomi.suwa")?.mangaId == "101")
        #expect(SuwayomiSourceConversion.perMangaKey("Manga.chapterSort.suwayomi.suwa.1596411039134168890.101", parent: "suwayomi.suwa") == nil)
        #expect(SuwayomiSourceConversion.perMangaKey(ChapterSortMemory.defaultKey, parent: "suwayomi.suwa") == nil)
    }
}
