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

    // STUB (rojo de L3): el contrato aún no tiene implementación
    func contains(_ id: MangaIdentifier) async -> Bool { false }
    func contained(in ids: [MangaIdentifier]) async -> Set<MangaIdentifier> { [] }
}
