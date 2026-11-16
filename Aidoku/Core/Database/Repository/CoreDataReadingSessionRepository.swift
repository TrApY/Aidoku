//
//  CoreDataReadingSessionRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataReadingSessionRepository: ReadingSessionRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    @discardableResult
    func add(_ data: HistoryManager.ReadingSessionData, chapter: ChapterIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.createSession(chapterId: chapter, data: data, context: context)
            return context.saveLogging("HistoryManager.addSession")
        }
    }
}
