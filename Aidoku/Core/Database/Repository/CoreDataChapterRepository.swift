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

    // STUB (rojo de L4): el contrato aún no tiene implementación
    func chapters(of manga: MangaIdentifier) async -> [AidokuRunner.Chapter] { [] }
    func chapter(_ id: ChapterIdentifier) async -> AidokuRunner.Chapter? { nil }
}
