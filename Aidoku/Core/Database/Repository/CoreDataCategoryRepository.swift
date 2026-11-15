//
//  CoreDataCategoryRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataCategoryRepository: CategoryRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    // STUB (rojo de L2): el contrato aún no tiene implementación
    func titles(includeFilterGroups: Bool) async -> [String] { [] }
    func filterGroupTitles() async -> [String] { [] }
    func filterGroups() async -> [FilterGroup] { [] }
    func filterGroup(title: String) async -> FilterGroup? { nil }
    func categories(of manga: MangaIdentifier) async -> [String] { [] }
    func contains(title: String) async -> Bool { false }
    func create(title: String) async -> Bool { false }
    func createFilterGroup(title: String, filters: [LibraryFilter]) async -> Bool { false }
    func updateFilterGroup(title: String, newTitle: String, filters: [LibraryFilter]) async -> Bool { false }
    func rename(_ title: String, to newTitle: String) async -> [String]? { nil }
    func remove(title: String) async -> Bool { false }
    func move(_ titles: [String], to position: Int) async -> Bool { false }
    func assign(_ manga: [MangaIdentifier], add titles: [String]) async -> Bool { false }
    func set(_ titles: [String], for manga: MangaIdentifier) async -> Bool { false }
    func remove(_ titles: [String], from manga: MangaIdentifier) async -> Bool { false }
}
