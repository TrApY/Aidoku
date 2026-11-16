//
//  CoreDataMangaUpdateRepository.swift
//  Aidoku
//

import AidokuRunner
import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataMangaUpdateRepository: MangaUpdateRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func recent(limit: Int, offset: Int) async -> [MangaUpdateEntry] {
        []
    }

    func markViewed(of manga: MangaIdentifier) async -> [MangaUpdateItem] {
        []
    }

    func remove(_ chapters: [ChapterIdentifier]) async -> Bool {
        false
    }
}
