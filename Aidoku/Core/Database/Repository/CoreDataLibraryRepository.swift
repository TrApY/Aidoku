//
//  CoreDataLibraryRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataLibraryRepository: LibraryRepository, @unchecked Sendable {
    /// ids looked up per background context in `contained(in:)`
    static let batchSize = 100

    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func contains(_ id: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasLibraryManga(mangaId: id, context: context)
        }
    }

    func contained(in ids: [MangaIdentifier]) async -> Set<MangaIdentifier> {
        var seen: Set<MangaIdentifier> = []
        let unique = ids.filter { seen.insert($0).inserted }
        var found: Set<MangaIdentifier> = []
        for start in stride(from: 0, to: unique.count, by: Self.batchSize) {
            let batch = Array(unique[start..<min(start + Self.batchSize, unique.count)])
            let inLibrary = await container.performBackgroundTask { context in
                batch.filter { CoreDataManager.shared.hasLibraryManga(mangaId: $0, context: context) }
            }
            found.formUnion(inLibrary)
        }
        return found
    }
}
