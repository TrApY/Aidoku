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
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getManga(mangaId: id, context: context)?.toNewManga()
        }
    }

    func contains(_ id: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasManga(mangaId: id, context: context)
        }
    }

    func chapterFilters(_ id: MangaIdentifier) async -> MangaChapterFilters {
        await container.performBackgroundTask { context in
            let filters = CoreDataManager.shared.getMangaChapterFilters(mangaId: id, context: context)
            return MangaChapterFilters(flags: filters.flags, language: filters.language, scanlators: filters.scanlators)
        }
    }

    func readingMode(_ id: MangaIdentifier) async -> Int {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getMangaSourceReadingMode(mangaId: id, context: context)
        }
    }

    func hasEditedKey(_ key: EditedKeys, _ id: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasEditedKey(mangaId: id, key: key, context: context)
        }
    }

    func setCover(_ id: MangaIdentifier, url: String?, original: Bool) async -> String? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.setCover(mangaId: id, coverUrl: url, original: original, context: context)
        }
    }

    @discardableResult
    func updateDetails(_ manga: AidokuRunner.Manga, filters: MangaChapterFilters) async -> Bool {
        await container.performBackgroundTask { context in
            let manga = manga.toOld()
            manga.chapterFlags = filters.flags
            manga.langFilter = filters.language
            manga.scanlatorFilter = filters.scanlators
            return CoreDataManager.shared.updateMangaDetails(manga: manga, context: context)
        }
    }
}
