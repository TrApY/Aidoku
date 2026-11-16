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
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getRecentMangaUpdates(limit: limit, offset: offset, context: context).compactMap { update in
                guard let mangaObject = CoreDataManager.shared.getManga(mangaId: update.identifier.mangaIdentifier, context: context) else {
                    return nil
                }
                return MangaUpdateEntry(
                    id: update.id,
                    chapterId: update.identifier,
                    date: update.date,
                    manga: mangaObject.toNewManga(),
                    chapter: update.chapter?.toChapter().toNew(),
                    chapterSourceOrder: update.chapter.map { Int($0.sourceOrder) },
                    viewed: update.viewed
                )
            }
        }
    }

    func markViewed(of manga: MangaIdentifier) async -> [MangaUpdateItem] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.setMangaUpdatesViewed(mangaId: manga, context: context).map { $0.toItem() }
        }
    }

    func remove(_ chapters: [ChapterIdentifier]) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.removeMangaUpdates(updates: chapters, context: context)
            return context.saveLogging("removeMangaUpdates")
        }
    }
}
