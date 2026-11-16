//
//  CoreDataChapterRepository.swift
//  Aidoku
//

import AidokuRunner
import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataChapterRepository: ChapterRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func chapters(of manga: MangaIdentifier) async -> [AidokuRunner.Chapter] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getChapters(mangaId: manga, context: context).map { $0.toNewChapter() }
        }
    }

    func chapter(_ id: ChapterIdentifier) async -> AidokuRunner.Chapter? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getChapter(chapterId: id, context: context)?.toNewChapter()
        }
    }

    func chaptersBlankAsNil(of manga: MangaIdentifier) async -> [AidokuRunner.Chapter] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getChapters(mangaId: manga, context: context).map { $0.toChapter().toNew() }
        }
    }

    func unreadCount(of manga: MangaIdentifier) async -> Int {
        await container.performBackgroundTask { context in
            // the filters and the count in one context, as the library did
            let filters = CoreDataManager.shared.getMangaChapterFilters(mangaId: manga, context: context)
            return CoreDataManager.shared.unreadCount(
                mangaId: manga,
                lang: filters.language,
                scanlators: filters.scanlators,
                context: context
            )
        }
    }

    /// In parallel, a context per manga, as the library did (D5).
    func unreadCounts(of mangas: [MangaIdentifier]) async -> [MangaIdentifier: Int] {
        await withTaskGroup(of: (MangaIdentifier, Int).self) { group in
            for manga in Set(mangas) {
                group.addTask {
                    let count = await self.unreadCount(of: manga)
                    return (manga, count)
                }
            }
            var counts: [MangaIdentifier: Int] = [:]
            for await (manga, count) in group {
                counts[manga] = count
            }
            return counts
        }
    }

    func unreadCount(of manga: MangaIdentifier, language: String?, scanlators: [String]?) async -> Int {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.unreadCount(mangaId: manga, lang: language, scanlators: scanlators, context: context)
        }
    }

    func readCount(of manga: MangaIdentifier, language: String?, scanlators: [String]?) async -> Int {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.readCount(mangaId: manga, lang: language, scanlators: scanlators, context: context)
        }
    }
}
