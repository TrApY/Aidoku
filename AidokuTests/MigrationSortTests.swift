//
//  MigrationSortTests.swift
//  AidokuTests
//
//  SUWA-12 I3: migrating a library manga takes the order chosen in its library flags: replacing, copying
//  (keeping the original) and when the new entry was already in the library.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct MigrationSortTests {
    private let ascending = ChapterSortChoice(option: ChapterSortOption.sourceOrder.rawValue, ascending: true)
    private let old = AidokuRunner.Manga(sourceKey: "ordenmigrar-vieja", key: "1", title: "Vieja")
    private let new = AidokuRunner.Manga(sourceKey: "ordenmigrar-nueva", key: "2", title: "Nueva")
    private let chapters: [AidokuRunner.Chapter] = [.init(key: "c2", chapterNumber: 2), .init(key: "c1", chapterNumber: 1)]

    private var environment: MigrationEnvironment {
        .init(trackerLookup: { _ in nil }, suwayomiTracker: nil, deleteDownloads: { _ in }, bindEnhancedTrackers: false)
    }

    private func setFlags(_ id: MangaIdentifier, _ flags: Int) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getManga(mangaId: id, context: context)?.chapterFlags = Int16(flags)
            try? context.save()
        }
    }

    private func cleanUp() async {
        for id in [old.identifier, new.identifier] {
            await MangaManager.shared.removeFromLibrary(mangaId: id)
            ChapterSortMemory.forgetLocal(id)
            await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.removeHistory(mangaId: id, context: context)
                CoreDataManager.shared.removeManga(mangaId: id, context: context)
                try? context.save()
            }
        }
    }

    /// Old in the library with ascending chosen (flags only), optionally the new one too; migrate; the
    /// order the new entry ends with.
    private func migrate(keepOriginal: Bool, newInLibrary: Bool) async -> ChapterSortChoice? {
        await cleanUp()
        await MangaManager.shared.addToLibrary(manga: old, chapters: chapters, bindTrackers: false)
        await setFlags(old.identifier, ChapterSortMemory.flags(ascending, into: 0))
        if newInLibrary {
            await MangaManager.shared.addToLibrary(manga: new, chapters: chapters, bindTrackers: false)
        }
        let options = MigrationOptions(readChapters: true, categories: true, tracking: false, keepOriginal: keepOriginal, deleteDownloads: false)
        _ = await MangaManager.migrate(options: options, from: old, to: new, withChapters: chapters, environment: environment)
        let newId = new.identifier
        let flags = await DataRepositories.shared.manga.chapterFilters(newId).flags
        await cleanUp()
        return ChapterSortMemory.chosen(inFlags: flags)
    }

    @Test func replacing() async {
        #expect(await migrate(keepOriginal: false, newInLibrary: false) == ascending)
    }

    @Test func copyingKeepingTheOriginal() async {
        #expect(await migrate(keepOriginal: true, newInLibrary: false) == ascending)
    }

    @Test func replacingWithTheNewOneAlreadyInTheLibrary() async {
        #expect(await migrate(keepOriginal: false, newInLibrary: true) == ascending)
    }

    @Test func copyingWithTheNewOneAlreadyInTheLibrary() async {
        #expect(await migrate(keepOriginal: true, newInLibrary: true) == ascending)
    }
}
