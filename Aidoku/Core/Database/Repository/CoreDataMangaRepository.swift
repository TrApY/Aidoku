//
//  CoreDataMangaRepository.swift
//  Aidoku
//

import AidokuRunner
import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataMangaRepository: MangaRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func manga(_ id: MangaIdentifier) async -> AidokuRunner.Manga? {
        nil
    }

    func contains(_ id: MangaIdentifier) async -> Bool {
        false
    }

    func chapterFilters(_ id: MangaIdentifier) async -> MangaChapterFilters {
        MangaChapterFilters(flags: 0)
    }

    func readingMode(_ id: MangaIdentifier) async -> Int {
        0
    }

    func hasEditedKey(_ key: EditedKeys, _ id: MangaIdentifier) async -> Bool {
        false
    }

    func setCover(_ id: MangaIdentifier, url: String?, original: Bool) async -> String? {
        nil
    }
}
