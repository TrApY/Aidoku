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
}
