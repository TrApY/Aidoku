//
//  CoreDataLibraryRepository.swift
//  Aidoku
//

import AidokuRunner
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

    func page(_ query: LibraryQuery) async -> LibraryPage? {
        await container.performBackgroundTask { context in
            var pinnedManga: [MangaInfo] = []
            var manga: [MangaInfo] = []
            var sourceKeys: Set<String> = []
            var unappliedFilters: [LibraryFilter] = []
            let filters = query.filters

            let request = LibraryMangaObject.fetchRequest()
            switch query.scope {
                case .all:
                    request.predicate = NSPredicate(format: "manga != nil")
                case .uncategorized:
                    request.predicate = NSPredicate(format: "manga != nil AND categories.@count == 0")
                case .category(let title):
                    request.predicate = NSPredicate(format: "manga != nil AND ANY categories.title == %@", title)
            }
            if let key = Self.sortKey(query.sort) {
                request.sortDescriptors = [NSSortDescriptor(key: key, ascending: query.ascending)]
            }
            guard let libraryObjects = try? context.fetch(request) else {
                return nil
            }

            var ids = Set<MangaIdentifier>()

            main: for libraryObject in libraryObjects {
                guard
                    let mangaObject = libraryObject.manga,
                    // ensure the manga hasn't already been accounted for
                    ids.insert(mangaObject.identifier).inserted
                else {
                    continue
                }

                let categories = (libraryObject.categories?.allObjects as? [CategoryObject])?.map { $0.title } ?? []

                let info = MangaInfo(
                    id: mangaObject.identifier,
                    coverUrl: mangaObject.cover.flatMap { URL(string: $0) },
                    title: mangaObject.title,
                    author: mangaObject.author,
                    url: mangaObject.url.flatMap { URL(string: $0) }
                )

                sourceKeys.insert(mangaObject.sourceId)

                // process filters
                var filteredSourceKeys: Set<String> = []
                var filteredContentRatings: Set<Int16> = []
                var filteredCategories: Set<String> = []
                for filter in filters {
                    let condition: Bool
                    switch filter.type {
                        case .downloaded:
                            unappliedFilters.append(filter)
                            continue
                        case .tracking:
                            condition = CoreDataManager.shared.hasTrack(
                                mangaId: info.id,
                                context: context
                            )
                        case .hasUnread:
                            unappliedFilters.append(filter)
                            continue
                        case .started:
                            condition = CoreDataManager.shared.hasHistory(
                                mangaId: info.id,
                                context: context
                            )
                        case .completed:
                            condition = mangaObject.status == AidokuRunner.PublishingStatus.completed.rawValue
                        case .source:
                            guard let sourceId = filter.value else { continue }
                            if filter.exclude {
                                condition = info.id.sourceKey == sourceId
                            } else {
                                // handle included source filters as OR
                                filteredSourceKeys.insert(sourceId)
                                continue
                            }
                        case .contentRating:
                            guard let contentRating = filter.value.flatMap(MangaContentRating.init) else { continue }
                            if filter.exclude {
                                condition = mangaObject.nsfw == contentRating.rawValue
                            } else {
                                // handle included content rating filters as OR
                                filteredContentRatings.insert(Int16(contentRating.rawValue))
                                continue
                            }
                        case .category:
                            guard let category = filter.value else { continue }
                            if filter.exclude {
                                condition = categories.contains(category)
                            } else {
                                // handle included category filters as OR
                                filteredCategories.insert(category)
                                continue
                            }

                    }
                    let shouldSkip = filter.exclude ? condition : !condition
                    if shouldSkip {
                        continue main
                    }
                }
                if !filteredSourceKeys.isEmpty && !filteredSourceKeys.contains(info.id.sourceKey) {
                    continue main
                }
                if !filteredContentRatings.isEmpty && !filteredContentRatings.contains(mangaObject.nsfw) {
                    continue main
                }
                if !filteredCategories.isEmpty && !filteredCategories.contains(where: { categories.contains($0) }) {
                    continue main
                }

                if query.pinUpdatedChapters && libraryObject.lastUpdatedChapters > libraryObject.lastOpened {
                    pinnedManga.append(info)
                } else {
                    manga.append(info)
                }
            }

            return LibraryPage(
                pinned: pinnedManga,
                manga: manga,
                sourceKeys: sourceKeys,
                isEmpty: libraryObjects.isEmpty,
                unappliedFilters: unappliedFilters
            )
        }
    }

    /// The stored key of each order (spec §2.3: the contract hides it).
    private static func sortKey(_ sort: LibraryQuery.Sort) -> String? {
        switch sort {
            case .title: "manga.title"
            case .lastRead: "lastRead"
            case .lastOpened: "lastOpened"
            case .lastUpdated: "lastUpdated"
            case .dateAdded: "dateAdded"
            case .lastChapter: "lastChapter"
            case .unreadChapters: nil
            case .totalChapters: "manga.chapterCount"
        }
    }

    func entries(sourceKey: String) async -> [AidokuRunner.Manga] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(sourceKey: sourceKey, context: context).compactMap { $0.manga?.toNewManga() }
        }
    }

    func entries(category: String?) async -> [AidokuRunner.Manga] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(category: category, context: context).compactMap { $0.manga?.toNewManga() }
        }
    }

    func entry(_ id: MangaIdentifier) async -> AidokuRunner.Manga? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(mangaId: id, context: context)?.manga?.toManga().toNew()
        }
    }

    func sourceKeysInLibrary() async -> Set<String> {
        await container.performBackgroundTask { context in
            let request = NSFetchRequest<NSDictionary>(entityName: "Manga")
            request.predicate = NSPredicate(format: "libraryObject != nil")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["sourceId"]
            request.returnsDistinctResults = true
            return Set(((try? context.fetch(request)) ?? []).compactMap { $0["sourceId"] as? String })
        }
    }

    func countInLibrary(sourceKeys: [String]) async -> Int? {
        await container.performBackgroundTask { context in
            let request = NSFetchRequest<NSManagedObject>(entityName: "LibraryManga")
            request.predicate = NSPredicate(format: "manga.sourceId IN %@", sourceKeys)
            return try? context.count(for: request)
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
