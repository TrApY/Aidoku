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
            // tracked and started manga, each in one query (not one per manga)
            let tracked = filters.contains { $0.type == .tracking } ? Self.mangaIds(entity: "Track", context: context) : []
            let started = filters.contains { $0.type == .started } ? Self.mangaIds(entity: "History", context: context) : []

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
                            condition = tracked.contains(info.id)
                        case .hasUnread:
                            unappliedFilters.append(filter)
                            continue
                        case .started:
                            condition = started.contains(info.id)
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

    /// The manga (source and key) with any row of that entity: what hasTrack/hasHistory ask one by one.
    private static func mangaIds(entity: String, context: NSManagedObjectContext) -> Set<MangaIdentifier> {
        let request = NSFetchRequest<NSDictionary>(entityName: entity)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["sourceId", "mangaId"]
        request.returnsDistinctResults = true
        let rows = (try? context.fetch(request)) ?? []
        return Set(rows.compactMap { row in
            guard let sourceKey = row["sourceId"] as? String, let mangaKey = row["mangaId"] as? String else { return nil }
            return MangaIdentifier(sourceKey: sourceKey, mangaKey: mangaKey)
        })
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

    func refreshEntries(category: String?) async -> [LibraryRefreshEntry] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(category: category, context: context)
                .compactMap { $0.manga?.toManga() }
                .map(LibraryRefreshEntry.init)
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

    func add(
        _ manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter],
        defaultCategory: String?,
        adoptChapterFlags: (@Sendable (Int) -> Int?)?
    ) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(manga: manga, chapters: chapters, context: context)
            if
                let adoptChapterFlags,
                let object = CoreDataManager.shared.getManga(mangaId: manga.identifier, context: context),
                let flags = adoptChapterFlags(Int(object.chapterFlags))
            {
                object.chapterFlags = Int16(flags)
            }
            if let defaultCategory, CoreDataManager.shared.hasCategory(title: defaultCategory, context: context) {
                CoreDataManager.shared.addCategoriesToManga(mangaId: manga.identifier, categories: [defaultCategory], context: context)
            }
            return context.saveLogging("MangaManager.addToLibrary")
        }
    }

    func remove(_ id: MangaIdentifier) async -> LibraryRemovalResult {
        await container.performBackgroundTask { context in
            var flags: [MangaIdentifier: Int] = [:]
            if let object = CoreDataManager.shared.getManga(mangaId: id, context: context) {
                flags[id] = Int(object.chapterFlags)
            }
            CoreDataManager.shared.removeManga(mangaId: id, context: context)
            CoreDataManager.shared.removeChapters(mangaId: id, context: context)
            CoreDataManager.shared.removeTracks(mangaId: id, context: context)
            return LibraryRemovalResult(chapterFlagsBefore: flags, saved: context.saveLogging("Failed to remove manga"))
        }
    }

    func remove(_ ids: [MangaIdentifier]) async -> LibraryRemovalResult {
        await container.performBackgroundTask { context in
            var flags: [MangaIdentifier: Int] = [:]
            for id in ids {
                if let object = CoreDataManager.shared.getManga(mangaId: id, context: context) {
                    flags[id] = Int(object.chapterFlags)
                }
            }
            CoreDataManager.shared.removeFromLibrary(ids: ids, context: context)
            return LibraryRemovalResult(chapterFlagsBefore: flags, saved: context.saveLogging("Failed to remove multiple manga"))
        }
    }

    func snapshot(_ ids: [MangaIdentifier]) async -> [LibrarySnapshot] {
        await container.performBackgroundTask { context in
            ids.compactMap { id -> LibrarySnapshot? in
                guard let manga = CoreDataManager.shared.getManga(mangaId: id, context: context)?.toManga() else {
                    return nil
                }
                var dates: LibraryDates?
                if
                    let lastOpened = manga.lastOpened,
                    let lastUpdated = manga.lastUpdated,
                    let lastUpdatedChapters = manga.lastUpdatedChapters,
                    let dateAdded = manga.dateAdded
                {
                    dates = LibraryDates(
                        dateAdded: dateAdded,
                        lastOpened: lastOpened,
                        lastUpdated: lastUpdated,
                        lastUpdatedChapters: lastUpdatedChapters,
                        lastChapter: manga.lastChapter,
                        lastRead: manga.lastRead
                    )
                }
                return LibrarySnapshot(
                    manga: manga.toNew(),
                    chapters: CoreDataManager.shared.getChapters(mangaId: id, context: context).map { $0.toChapter().toNew() },
                    dates: dates,
                    tracks: CoreDataManager.shared.getTracks(mangaId: id, context: context).map { $0.toItem() },
                    categories: CoreDataManager.shared.getCategories(mangaId: id, context: context).compactMap { $0.title }
                )
            }
        }
    }

    func restore(_ snapshot: LibrarySnapshot) async -> Bool {
        await container.performBackgroundTask { context in
            let manga = snapshot.manga
            CoreDataManager.shared.addToLibrary(manga: manga, chapters: snapshot.chapters, context: context)
            if
                let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: manga.identifier, context: context),
                let dates = snapshot.dates
            {
                libraryObject.lastOpened = dates.lastOpened
                libraryObject.lastUpdated = dates.lastUpdated
                libraryObject.lastUpdatedChapters = dates.lastUpdatedChapters
                libraryObject.lastChapter = dates.lastChapter
                libraryObject.lastRead = dates.lastRead
                libraryObject.dateAdded = dates.dateAdded
            }
            for item in snapshot.tracks {
                CoreDataManager.shared.createTrack(
                    id: item.id,
                    trackerId: item.trackerId,
                    mangaId: item.mangaId,
                    title: item.title,
                    context: context
                )
            }
            for category in snapshot.categories where !CoreDataManager.shared.hasCategory(title: category, context: context) {
                CoreDataManager.shared.createCategory(title: category, context: context)
            }
            CoreDataManager.shared.addCategoriesToManga(mangaId: manga.identifier, categories: snapshot.categories, context: context)
            return context.saveLogging("MangaManager.restoreToLibrary")
        }
    }

    func markOpened(_ id: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            guard let object = CoreDataManager.shared.getLibraryManga(mangaId: id, context: context) else {
                return true
            }
            object.lastOpened = Date()
            return context.saveLogging("setOpened")
        }
    }

    func resetLastUpdatedChapters() async {
        await container.performBackgroundTask { context in
            let items = CoreDataManager.shared.getLibraryManga(context: context)
            // if lastUpdatedChapters is set to the default value, update default to lastUpdated (never saved)
            for item in items where item.lastUpdatedChapters.timeIntervalSince1970 == 21600 {
                item.lastUpdatedChapters = item.lastUpdated
            }
        }
    }

    func refresh(_ id: MangaIdentifier, with manga: AidokuRunner.Manga, updateMetadata: Bool) async -> RefreshOutcome? {
        await container.performBackgroundTask { context in
            guard
                let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: id, context: context),
                let mangaObject = libraryObject.manga
            else {
                return nil
            }

            // update details
            if updateMetadata {
                mangaObject.load(from: manga)
            }

            // update chapters
            guard let chapters = manga.chapters, !chapters.isEmpty else { return nil }

            let newChapters = CoreDataManager.shared.setChapters(chapters, mangaId: id, context: context)
            var notifiableCount = 0
            if !newChapters.isEmpty {
                // add manga updates
                let scanlatorFilter = mangaObject.scanlatorFilter ?? []
                for chapter in newChapters where Self.makesUpdate(chapter, language: mangaObject.langFilter, scanlators: scanlatorFilter) {
                    CoreDataManager.shared.createMangaUpdate(mangaId: id, chapterObject: chapter, context: context)
                    notifiableCount += 1
                }
                libraryObject.lastChapter = chapters.compactMap { $0.dateUploaded }.max()
                libraryObject.lastUpdatedChapters = Date.now
            }

            if updateMetadata || !newChapters.isEmpty {
                libraryObject.lastUpdated = Date.now
            }

            if context.hasChanges {
                try? context.save()
            }
            return RefreshOutcome(newChapterCount: newChapters.count, notifiableCount: notifiableCount, title: mangaObject.title)
        }
    }

    func refreshOpened(
        _ id: MangaIdentifier,
        with manga: AidokuRunner.Manga,
        languageFilter: String?,
        scanlatorFilter: [String],
        incognito: Bool
    ) async -> OpenedRefresh? {
        await container.performBackgroundTask { context in
            guard
                let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: id, context: context),
                let mangaObject = libraryObject.manga
            else {
                return nil
            }

            // update details
            mangaObject.load(from: manga)

            var foundNewChapters = false
            if let chapters = manga.chapters {
                let newChapters = CoreDataManager.shared.setChapters(chapters, mangaId: id, context: context)
                if !newChapters.isEmpty {
                    foundNewChapters = true
                    // add manga updates
                    for chapter in newChapters where Self.makesUpdate(chapter, language: languageFilter, scanlators: scanlatorFilter) {
                        CoreDataManager.shared.createMangaUpdate(mangaId: id, chapterObject: chapter, context: context)
                    }
                    libraryObject.lastChapter = chapters.compactMap { $0.dateUploaded }.max()
                    libraryObject.lastUpdatedChapters = Date.now
                }
            }

            let now = Date.now
            libraryObject.lastUpdated = now
            if !incognito {
                libraryObject.lastOpened = now.addingTimeInterval(1) // ensure item isn't re-pinned, since it's already open
            }

            try? context.save()

            return OpenedRefresh(manga: mangaObject.toNewManga(), foundNewChapters: foundNewChapters)
        }
    }

    /// Whether a new chapter makes an update entry, with the condition both refreshes had, written the same way:
    /// by the precedence of `?:`, with a language filter the scanlator filter is not looked at (§1.5 nº 12).
    private static func makesUpdate(_ chapter: ChapterObject, language: String?, scanlators: [String]) -> Bool {
        language != nil ? chapter.lang == language : true
            && !scanlators.isEmpty ? scanlators.contains(chapter.scanlator ?? "") : true
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

    func migrate(_ request: MigrationRequest) async -> MigrationOutcome? {
        // the names MangaManager.migrate gave them, so the transaction below reads as it did there
        let oldManga = request.old
        let newManga = request.new
        let newChapters = request.newChapters
        let options = request.options
        let copy = options.keepOriginal
        let newWasInLibrary = request.newWasInLibrary
        let suwayomiTrackerId = request.suwayomiTrackerId
        let suwayomiNewTrackId = request.suwayomiNewTrackId
        // one context and one save, with the context's own merge policy (D-L11-3)
        return await container.performBackgroundTask { context in
            do {
                // the order chosen in the old library entry (its flags), before it may go (SUWA-12 I3)
                let oldSort = CoreDataManager.shared.getManga(mangaId: oldManga.identifier, context: context)
                    .flatMap { ChapterSortMemory.chosen(inFlags: Int($0.chapterFlags)) }
                // update manga object in library with new data
                // remove old entry if the new one already exists in library
                if !copy {
                    var mangaObjectToUpdate: MangaObject?
                    let oldCategories = CoreDataManager.shared.getCategories(mangaId: oldManga.identifier, context: context)

                    // new is already in library
                    if newManga.key != oldManga.key, let storedNewManga = CoreDataManager.shared.getManga(
                        mangaId: newManga.identifier,
                        context: context
                    ) {
                        // update the object in the library with the new details we fetched already
                        mangaObjectToUpdate = storedNewManga
                        // remove old entry
                        CoreDataManager.shared.removeManga(
                            mangaId: oldManga.identifier,
                            context: context
                        )
                        mangaObjectToUpdate?.load(from: newManga)
                        // it keeps its own categories, plus the old ones if asked
                        if options.categories {
                            CoreDataManager.shared.addCategoriesToManga(
                                mangaId: newManga.identifier,
                                categories: oldCategories,
                                context: context
                            )
                        }
                    } else {
                        // get existing old object to replace data with new details
                        mangaObjectToUpdate = CoreDataManager.shared.getManga(
                            mangaId: oldManga.identifier,
                            context: context
                        )
                        let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: oldManga.identifier, context: context)
                        mangaObjectToUpdate?.load(from: newManga)
                        // the old library object stays: drop what wasn't asked for
                        if let libraryObject {
                            if !options.categories {
                                libraryObject.categories = NSSet()
                            }
                            if !options.readChapters {
                                libraryObject.lastRead = nil
                            }
                        }
                    }
                }

                // copy categories
                if copy && options.categories {
                    let categories = CoreDataManager.shared.getCategories(
                        mangaId: oldManga.identifier,
                        context: context
                    )
                    CoreDataManager.shared.addCategoriesToManga(
                        mangaId: newManga.identifier,
                        categories: categories,
                        context: context
                    )
                } else if copy && !newWasInLibrary,
                          let libraryObject = CoreDataManager.shared.getLibraryManga(mangaId: newManga.identifier, context: context) {
                    // without categories (also without the default one it got when added)
                    libraryObject.categories = NSSet()
                }

                // ... goes to the new entry: replaced, copied or already in the library
                if let oldSort, let newObject = CoreDataManager.shared.getManga(mangaId: newManga.identifier, context: context) {
                    newObject.chapterFlags = Int16(ChapterSortMemory.flags(oldSort, into: Int(newObject.chapterFlags)))
                }

                // migrate history
                let storedOldHistory = CoreDataManager.shared.getHistoryForManga(
                    mangaId: oldManga.identifier,
                    context: context
                )

                // read = completed only; unfinished chapters keep their page; dates are kept
                let historyPlan = MigrationHistory.plan(
                    old: storedOldHistory.map {
                        .init(
                            chapter: $0.chapter?.chapter?.floatValue,
                            volume: $0.chapter?.volume?.floatValue,
                            completed: $0.completed,
                            progress: Int($0.progress),
                            total: Int($0.total),
                            dateRead: $0.dateRead,
                            scrollPosition: $0.scrollPosition?.doubleValue
                        )
                    },
                    newChapters: newChapters
                )

                // remove old chapters and history
                if !copy {
                    CoreDataManager.shared.removeChapters(
                        mangaId: oldManga.identifier,
                        context: context
                    )

                    CoreDataManager.shared.removeHistory(
                        mangaId: oldManga.identifier,
                        context: context
                    )

                    // store new chapters
                    CoreDataManager.shared.setChapters(
                        newChapters,
                        mangaId: newManga.identifier,
                        context: context
                    )
                }

                // mark new chapters as read, with the old reading dates (only if asked)
                // the journal lines go back to the service, which writes them once saved (D-L11-2)
                var completions: [MigrationOutcome.Completion] = []
                for completed in options.readChapters ? historyPlan.completed : [] {
                    completions.append(.init(
                        chapter: .init(sourceKey: newManga.sourceKey, mangaKey: newManga.key, chapterKey: completed.chapterKey),
                        reason: "migración desde \(oldManga.identifier)"
                    ))
                    CoreDataManager.shared.setCompleted(
                        chapterIds: [.init(sourceKey: newManga.sourceKey, mangaKey: newManga.key, chapterKey: completed.chapterKey)],
                        date: completed.date,
                        context: context
                    )
                }
                // the unfinished chapter keeps its page (unless the new chapter already has its own history)
                for unfinished in options.readChapters ? historyPlan.inProgress : [] {
                    let chapterId = ChapterIdentifier(sourceKey: newManga.sourceKey, mangaKey: newManga.key, chapterKey: unfinished.chapterKey)
                    if let existing = CoreDataManager.shared.getHistory(chapterId: chapterId, context: context),
                       existing.completed || existing.progress > 0 {
                        continue
                    }
                    CoreDataManager.shared.setProgress(
                        unfinished.progress,
                        chapterId: chapterId,
                        totalPages: unfinished.total > 0 ? unfinished.total : nil,
                        scrollPosition: unfinished.scrollPosition,
                        dateRead: unfinished.date,
                        context: context
                    )
                }

                // migrate trackers
                let trackItems = CoreDataManager.shared.getTracks(
                    mangaId: oldManga.identifier,
                    context: context
                )

                for item in trackItems {
                    guard let trackId = item.id, let trackerId = item.trackerId else {
                        if !copy && newManga.identifier != oldManga.identifier {
                            context.delete(item) // a broken item doesn't stay behind
                        }
                        continue
                    }
                    let isSuwayomi = trackerId == suwayomiTrackerId
                    let action = MigrationOptions.trackAction(
                        isSuwayomi: isSuwayomi,
                        trackId: trackId,
                        suwayomiNewTrackId: suwayomiNewTrackId,
                        keepOriginal: copy,
                        sameEntry: newManga.identifier == oldManga.identifier,
                        newHasTrack: CoreDataManager.shared.hasTrack(trackerId: trackerId, mangaId: newManga.identifier, context: context),
                        tracking: options.tracking,
                        canTrackNew: !isSuwayomi && request.canTrackNew(trackerId)
                    )
                    switch action {
                        case .keep:
                            break
                        case .delete:
                            context.delete(item)
                        case let .move(id):
                            if let id {
                                item.id = id
                            }
                            item.sourceId = newManga.sourceKey
                            item.mangaId = newManga.key
                        case let .copy(id):
                            CoreDataManager.shared.createTrack(
                                id: id,
                                trackerId: trackerId,
                                mangaId: newManga.identifier,
                                title: item.title,
                                context: context
                            )
                    }
                }

                try context.save()

                return MigrationOutcome(from: oldManga, to: newManga, completions: completions)
            } catch {
                LogManager.logger.error("Error migrating manga \(oldManga.key): \(error)")
                return nil
            }
        }
    }

    func identifiersToRemap(sourceKey: String) async -> IdentifiersToRemap {
        await container.performBackgroundTask { context in
            let historyObjects = CoreDataManager.shared.getHistory(sourceKey: sourceKey, context: context)
            return IdentifiersToRemap(
                libraryMangaKeys: CoreDataManager.shared.getLibraryManga(sourceKey: sourceKey, context: context)
                    .compactMap { $0.manga?.id },
                chapters: CoreDataManager.shared.getChapters(sourceKey: sourceKey, context: context)
                    .map { (mangaKey: $0.mangaId, chapterKey: $0.id) },
                historyMangaKeys: historyObjects.map { $0.mangaId },
                historyChapters: historyObjects.map { (mangaKey: $0.mangaId, chapterKey: $0.chapterId) }
            )
        }
    }

    func remapIdentifiers(_ remap: IdentifierRemap) async -> Bool {
        let sourceKey = remap.sourceKey
        let newMangaIds = remap.mangaKeys
        let newChapterIds = remap.chapterKeys
        return await container.performBackgroundTask { context in
            let libraryObjects = CoreDataManager.shared.getLibraryManga(sourceKey: sourceKey, context: context)
            let chapterObjects = CoreDataManager.shared.getChapters(sourceKey: sourceKey, context: context)
            let historyObjects = CoreDataManager.shared.getHistory(sourceKey: sourceKey, context: context)
            for object in libraryObjects {
                guard
                    let oldId = object.manga?.id,
                    let newId = newMangaIds[oldId]
                else { continue }
                object.manga?.id = newId
            }
            for object in chapterObjects {
                object.mangaId = newMangaIds[object.mangaId] ?? object.mangaId
                object.id = newChapterIds[object.id] ?? object.id
            }
            for object in historyObjects {
                object.mangaId = newMangaIds[object.mangaId] ?? object.mangaId
                object.chapterId = newChapterIds[object.chapterId] ?? object.chapterId
            }
            return context.saveLogging("Failed to save id migration")
        }
    }
}
