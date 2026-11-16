//
//  CoreDataHistoryRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataHistoryRepository: HistoryRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    static func record(_ object: HistoryObject) -> HistoryRecord {
        HistoryRecord(
            chapterId: object.identifier,
            progress: Int(object.progress),
            total: Int(object.total),
            completed: object.completed,
            dateRead: object.dateRead,
            scrollPosition: object.scrollPosition?.doubleValue
        )
    }

    static func progress(_ stored: (completed: Bool, progress: Int?)) -> ChapterProgress {
        ChapterProgress(completed: stored.completed, progress: stored.progress)
    }

    func progress(of chapter: ChapterIdentifier) async -> ChapterProgress {
        await container.performBackgroundTask { context in
            Self.progress(CoreDataManager.shared.getProgress(chapterId: chapter, context: context))
        }
    }

    func record(of chapter: ChapterIdentifier) async -> HistoryRecord? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getHistory(chapterId: chapter, context: context).map(Self.record)
        }
    }

    func readingHistory(of manga: MangaIdentifier) async -> [String: ReadingHistoryEntry] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getReadingHistory(mangaId: manga, context: context)
                .mapValues { ReadingHistoryEntry(page: $0.page, date: $0.date) }
        }
    }

    func recent(limit: Int, offset: Int) async -> [HistoryRecord] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getRecentHistory(limit: limit, offset: offset, context: context).map(Self.record)
        }
    }

    func hasHistory(of manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasHistory(mangaId: manga, context: context)
        }
    }

    func earliestReadDate(of manga: MangaIdentifier) async -> Date? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getEarliestReadDate(mangaId: manga, context: context)
        }
    }

    func highestReadNumber(of manga: MangaIdentifier, mode: ChapterTitleDisplayMode) async -> Float? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getHighestReadNumber(mangaId: manga, mode: mode, context: context)
        }
    }

    // STUB (rojo de L5): las escrituras aún no tienen implementación
    func savePage(_ save: PageSave) async -> Bool { false }
    func markCompleted(_ chapters: [ChapterIdentifier], date: Date) async -> Bool? { false }
    func remove(chapters: [ChapterIdentifier]) async -> Bool { false }
    func removeAll(of manga: MangaIdentifier) async -> Bool { false }
    func clear(excludingLibrary: Bool) async -> Bool { false }
}
