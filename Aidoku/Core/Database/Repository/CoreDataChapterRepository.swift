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
}
