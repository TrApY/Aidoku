//
//  CoreDataRepositories.swift
//  Aidoku
//
//  SUWA-13 F4: the Core Data implementation of the repositories, on the app's container (`shared`) or on any
//  other one (tests). Each repository wraps the CoreDataManager functions of its domain as they are.
//

import CoreData

extension DataRepositories {
    /// The repositories on the app's container.
    static let shared = DataRepositories(container: CoreDataManager.shared.container)

    init(container: NSPersistentContainer) {
        self.init(
            tracks: CoreDataTrackRepository(container: container),
            categories: CoreDataCategoryRepository(container: container),
            library: CoreDataLibraryRepository(container: container),
            history: CoreDataHistoryRepository(container: container),
            chapters: CoreDataChapterRepository(container: container),
            manga: CoreDataMangaRepository(container: container),
            mangaUpdates: CoreDataMangaUpdateRepository(container: container),
            sessions: CoreDataReadingSessionRepository(container: container),
            mainActorReads: CoreDataMainActorReads(container: container)
        )
    }
}

extension NSManagedObjectContext {
    /// Saves; a failure is logged and swallowed, as the callers did before (D1).
    func saveLogging(_ what: String) -> Bool {
        do {
            try save()
            return true
        } catch {
            LogManager.logger.error("\(what): \(error)")
            return false
        }
    }
}
