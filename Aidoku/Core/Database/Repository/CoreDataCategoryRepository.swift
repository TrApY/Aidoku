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

    func titles(includeFilterGroups: Bool) async -> [String] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getCategoryTitles(excludeFilterGroups: !includeFilterGroups, context: context)
        }
    }

    func filterGroupTitles() async -> [String] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getCategories(groupsOnly: true, context: context).compactMap { $0.title }
        }
    }

    func filterGroups() async -> [FilterGroup] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getFilterGroups(context: context)
        }
    }

    func filterGroup(title: String) async -> FilterGroup? {
        await container.performBackgroundTask { context in
            Self.filterGroup(title: title, context: context)
        }
    }

    private static func filterGroup(title: String, context: NSManagedObjectContext) -> FilterGroup? {
        guard
            let category = CoreDataManager.shared.getCategory(title: title, context: context),
            let data = category.data as? Data,
            let filters = try? JSONDecoder().decode([LibraryFilter].self, from: data)
        else {
            return nil
        }
        return FilterGroup(title: title, filters: filters)
    }

    func snapshot(of manga: MangaIdentifier?, filterGroup title: String?) async -> CategorySnapshot {
        await container.performBackgroundTask { context in
            let manager = CoreDataManager.shared
            let mangaCategories = manga.map { id in
                manager.getCategories(mangaId: id, context: context).compactMap { category in category.title }
            }
            return CategorySnapshot(
                titles: manager.getCategoryTitles(excludeFilterGroups: true, context: context),
                titlesAndGroups: manager.getCategoryTitles(excludeFilterGroups: false, context: context),
                filterGroups: manager.getFilterGroups(context: context),
                categoriesOfManga: mangaCategories ?? [],
                filterGroup: title.flatMap { groupTitle in Self.filterGroup(title: groupTitle, context: context) }
            )
        }
    }

    func categories(of manga: MangaIdentifier) async -> [String] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getCategories(mangaId: manga, context: context).compactMap { $0.title }
        }
    }

    func contains(title: String) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasCategory(title: title, context: context)
        }
    }

    @discardableResult
    func create(title: String) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.createCategory(title: title, context: context)
            return context.saveLogging("CategoryRepository.create")
        }
    }

    @discardableResult
    func createFilterGroup(title: String, filters: [LibraryFilter]) async -> Bool {
        guard let data = try? JSONEncoder().encode(filters) else {
            LogManager.logger.error("Failed to encode filters data")
            return false
        }
        return await container.performBackgroundTask { context in
            let category = CoreDataManager.shared.createCategory(title: title, group: true, context: context)
            category.data = data as NSObject
            return context.saveLogging("CategoryRepository.createFilterGroup")
        }
    }

    @discardableResult
    func updateFilterGroup(title: String, newTitle: String, filters: [LibraryFilter]) async -> Bool {
        guard let data = try? JSONEncoder().encode(filters) else {
            LogManager.logger.error("Failed to encode filters data")
            return false
        }
        return await container.performBackgroundTask { context in
            guard let category = CoreDataManager.shared.getCategory(title: title, context: context) else {
                return true
            }
            category.title = newTitle
            category.data = data as NSObject
            return context.saveLogging("CategoryRepository.updateFilterGroup")
        }
    }

    func rename(_ title: String, to newTitle: String) async -> [String]? {
        await container.performBackgroundTask { context in
            guard
                CoreDataManager.shared.renameCategory(title: title, newTitle: newTitle, context: context),
                context.saveLogging("CategoryRepository.rename(\(title))")
            else {
                return nil
            }
            return CoreDataManager.shared.getCategoryTitles(context: context)
        }
    }

    @discardableResult
    func remove(title: String) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.removeCategory(title: title, context: context)
            return context.saveLogging("CategoryRepository.remove(\(title))")
        }
    }

    @discardableResult
    func move(_ titles: [String], to position: Int) async -> Bool {
        await container.performBackgroundTask { context in
            for title in titles {
                CoreDataManager.shared.moveCategory(title: title, toPosition: position, context: context)
            }
            return context.saveLogging("CategoryRepository.move")
        }
    }

    @discardableResult
    func assign(_ manga: [MangaIdentifier], add titles: [String]) async -> Bool {
        await container.performBackgroundTask { context in
            var saved = true
            for id in manga {
                CoreDataManager.shared.addCategoriesToManga(mangaId: id, categories: titles, context: context)
                if !context.saveLogging("CategoryRepository.assign") {
                    saved = false
                }
            }
            return saved
        }
    }

    @discardableResult
    func set(_ titles: [String], for manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            guard let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: manga, context: context) else {
                return true
            }
            libraryObject.categories = NSSet(array: titles.compactMap {
                CoreDataManager.shared.getCategory(title: $0, context: context)
            })
            return context.saveLogging("CategoryRepository.set")
        }
    }

    @discardableResult
    func remove(_ titles: [String], from manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            guard let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: manga, context: context) else {
                return true
            }
            for title in titles {
                guard let category = CoreDataManager.shared.getCategory(title: title, context: context) else { continue }
                libraryObject.removeFromCategories(category)
            }
            return context.saveLogging("CategoryRepository.remove(_:from:)")
        }
    }
}
