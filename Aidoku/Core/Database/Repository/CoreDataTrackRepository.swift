//
//  CoreDataTrackRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataTrackRepository: TrackRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    // STUB (rojo de L1): el contrato aún no tiene implementación
    func items(of manga: MangaIdentifier) async -> [TrackItem] { [] }
    func items(trackerId: String) async -> [TrackItem] { [] }
    func contains(manga: MangaIdentifier) async -> Bool { false }
    func contains(trackerId: String, manga: MangaIdentifier) async -> Bool { false }
    func add(_ item: TrackItem) async -> Bool { false }
    func setChapterOffset(trackerId: String, manga: MangaIdentifier, offset: Int) async -> Bool { false }
    func remove(trackerId: String, manga: MangaIdentifier) async -> Bool { false }
    func removeAll(trackerId: String) async -> Bool { false }
    func removeAll(trackerId: String, where idMatches: @escaping @Sendable (String) throws -> Bool) async -> Bool { false }
    func clearAll() async -> Bool { false }
}
