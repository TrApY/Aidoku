//
//  CoreDataMainActorReads.swift
//  Aidoku
//

import CoreData

/// Reads through the container's view context, like the @MainActor overloads of CoreDataManager.
@MainActor
final class CoreDataMainActorReads: MainActorReads {
    private let container: NSPersistentContainer

    nonisolated init(container: NSPersistentContainer) {
        self.container = container
    }

    func isTracking(_ manga: MangaIdentifier) -> Bool {
        CoreDataManager.shared.hasTrack(mangaId: manga, context: container.viewContext)
    }

    func progress(of chapter: ChapterIdentifier) -> ChapterProgress {
        CoreDataHistoryRepository.progress(CoreDataManager.shared.getProgress(chapterId: chapter, context: container.viewContext))
    }

    func record(of chapter: ChapterIdentifier) -> HistoryRecord? {
        CoreDataManager.shared.getHistory(chapterId: chapter, context: container.viewContext).map(CoreDataHistoryRepository.record)
    }

    func manga(contains id: MangaIdentifier) -> Bool {
        CoreDataManager.shared.hasManga(mangaId: id, context: container.viewContext)
    }

    func readingMode(of id: MangaIdentifier) -> Int {
        CoreDataManager.shared.getMangaSourceReadingMode(mangaId: id, context: container.viewContext)
    }
}
