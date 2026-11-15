//
//  MangaManager.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/14/22.
//

import AidokuRunner
import BackgroundTasks
import CoreData
import Nuke
import UIKit

actor MangaManager {
    static let shared = MangaManager()

    private static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".libraryRefresh"

    private var libraryRefreshTask: Task<(), Never>?
    private var libraryRefreshProgressTask: Task<(), Never>?
    private var onLibraryRefreshProgress: (@MainActor (Progress) -> Void)?

    private var targetCategory: String?
    private var skipReachabilityCheck: Bool = false

    private static let maxConcurrentLibraryUpdateTasks = 10

    nonisolated func getNextChapter(
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter],
        readingHistory: [String: (page: Int, date: Int)],
        sortAscending: Bool
    ) -> AidokuRunner.Chapter? {
        let resumeLastOpened = AppSettings.library.resumeLastOpenedChapter.get()

        // 1. Resume Reading: Find the most recently read chapter that isn't
        // completed, unless the "resume last opened" option is enabled.
        var selectedChapter: AidokuRunner.Chapter?
        var selectedDate: Int = -1

        for chapter in chapters {
            guard
                let history = readingHistory[chapter.id],
                resumeLastOpened || history.page != -1,
                history.date > selectedDate
            else { continue }

            if chapter.locked {
                let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
                let isDownloaded = DownloadManager.shared.getDownloadStatus(for: identifier) == .finished
                guard isDownloaded else { continue }
            }

            selectedDate = history.date
            selectedChapter = chapter
        }

        if let selectedChapter {
            return selectedChapter
        }

        // 2. Fallback: Find first uncompleted chapter in sort order (Start Reading)
        let sorted = sortAscending ? chapters : chapters.reversed()

        return sorted.first(where: { chapter in
            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
            let isDownloaded = DownloadManager.shared.getDownloadStatus(for: identifier) == .finished
            let isUnlocked = !chapter.locked || isDownloaded
            let history = readingHistory[chapter.id]
            let isCompleted = history?.page ?? 0 == -1

            return isUnlocked && !isCompleted
        })
    }

    /// Fetches the stored chapters for a manga in the user's sort order, along with the next chapter to read.
    nonisolated func getNextChapter(
        mangaId: MangaIdentifier,
        fallbackChapters: [AidokuRunner.Chapter]? = nil,
        fetchIfNeeded: Bool = false
    ) async -> (chapters: [AidokuRunner.Chapter], nextChapter: AidokuRunner.Chapter?) {
        let readingHistory = await CoreDataManager.shared.getReadingHistory(mangaId: mangaId)
        var chapters = await CoreDataManager.shared.getChapters(mangaId: mangaId)
            .map { $0.toNew() }

        // chapters are only stored for manga in the library, so fall back to the ones we have loaded
        if chapters.isEmpty {
            if let fallbackChapters, !fallbackChapters.isEmpty {
                chapters = fallbackChapters
            } else if fetchIfNeeded, let source = await SourceManager.shared.source(for: mangaId.sourceKey) {
                let manga = AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: "")
                let updatedManga = try? await source.getMangaUpdate(
                    manga: manga,
                    needsDetails: false,
                    needsChapters: true
                )
                chapters = updatedManga?.chapters ?? []
            }
        }

        let filters = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getMangaChapterFilters(
                mangaId: mangaId,
                context: context
            )
        }
        let sortOption = ChapterSortOption(flags: filters.flags)
        let sortAscending = filters.flags & ChapterFlagMask.sortAscending != 0

        let sortedChapters: [AidokuRunner.Chapter] = switch sortOption {
            case .sourceOrder:
                sortAscending ? chapters.reversed() : chapters
            case .chapter:
                chapters.sorted {
                    let lhs = $0.chapterNumber ?? -1
                    let rhs = $1.chapterNumber ?? -1
                    return sortAscending ? lhs < rhs : lhs > rhs
                }
            case .uploadDate:
                chapters.sorted {
                    let lhs = $0.dateUploaded ?? .distantPast
                    let rhs = $1.dateUploaded ?? .distantPast
                    return sortAscending ? lhs < rhs : lhs > rhs
                }
        }

        let manga = AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: "")
        let nextChapter = getNextChapter(
            manga: manga,
            chapters: sortedChapters,
            readingHistory: readingHistory,
            sortAscending: sortAscending
        )

        return (sortedChapters, nextChapter)
    }
}

// MARK: - Library Managing
extension MangaManager {
    func addToLibrary(
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter] = [],
        fetchMangaDetails: Bool = false,
        bindTrackers: Bool = true
    ) async {
        var manga = manga
        var chapters = chapters
        // update manga or chapters
        if fetchMangaDetails || chapters.isEmpty {
            if let source = await SourceManager.shared.source(for: manga.sourceKey) {
                manga = (try? await source.getMangaUpdate(manga: manga, needsDetails: fetchMangaDetails, needsChapters: chapters.isEmpty)) ?? manga
                chapters = manga.chapters ?? chapters
            }
        }
        await CoreDataManager.shared.container.performBackgroundTask { [manga, chapters] context in
            CoreDataManager.shared.addToLibrary(
                manga: manga,
                chapters: chapters,
                context: context
            )
            // add to default category
            let defaultCategory = AppSettings.library.defaultCategory.get()
            if let defaultCategory {
                let hasCategory = CoreDataManager.shared.hasCategory(title: defaultCategory, context: context)
                if hasCategory {
                    CoreDataManager.shared.addCategoriesToManga(
                        mangaId: manga.identifier,
                        categories: [defaultCategory],
                        context: context
                    )
                }
            }
            do {
                try context.save()
            } catch {
                LogManager.logger.error("MangaManager.addToLibrary: \(error.localizedDescription)")
            }
        }
        // add enhanced trackers
        if bindTrackers {
            await TrackerManager.shared.bindEnhancedTrackers(manga: manga)
        }

        let mangaId = manga.identifier
        await MainActor.run {
            NotificationCenter.default.post(name: .addToLibrary, object: mangaId)
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
        }
    }

    func removeFromLibrary(mangaId: MangaIdentifier) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeManga(mangaId: mangaId, context: context)
            CoreDataManager.shared.removeChapters(mangaId: mangaId, context: context)
            CoreDataManager.shared.removeTracks(mangaId: mangaId, context: context)
            do {
                try context.save()
            } catch {
                LogManager.logger.error("Failed to remove manga: \(error)")
            }
        }
        DownloadAheadSetting.set(0, for: mangaId)
        await MainActor.run {
            NotificationCenter.default.post(name: .removeFromLibrary, object: mangaId)
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
            NotificationCenter.default.post(name: .updateTrackers, object: nil)
        }
    }

    func removeFromLibrary(mangaIds: [MangaIdentifier]) async {
        if mangaIds.count > 100 {
            await UIApplication.shared.appDelegate?.showLoadingIndicator()
        }
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeFromLibrary(ids: mangaIds, context: context)
            do {
                try context.save()
            } catch {
                LogManager.logger.error("Failed to remove multiple manga: \(error)")
            }
        }
        for mangaId in mangaIds {
            DownloadAheadSetting.set(0, for: mangaId)
        }
        await MainActor.run {
            for id in mangaIds {
                NotificationCenter.default.post(name: .removeFromLibrary, object: id)
            }
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
            NotificationCenter.default.post(name: .updateTrackers, object: nil)
        }
        await UIApplication.shared.appDelegate?.hideLoadingIndicator()
    }

    /// - downloadAhead: the manga's «descarga adelantada» setting when it was removed (undo).
    func restoreToLibrary(
        manga: Manga,
        chapters: [Chapter],
        trackItems: [TrackItem],
        categories: [String],
        downloadAhead: Int = 0
    ) async {
        let newManga = manga.toNew()
        let newChapters = chapters.map { $0.toNew() }
        let lastOpened = manga.lastOpened
        let lastUpdated = manga.lastUpdated
        let lastUpdatedChapters = manga.lastUpdatedChapters
        let lastChapter = manga.lastChapter
        let lastRead = manga.lastRead
        let dateAdded = manga.dateAdded

        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(
                manga: newManga,
                chapters: newChapters,
                context: context
            )

            if let libraryObject = CoreDataManager.shared.getLibraryManga(
                mangaId: newManga.identifier,
                context: context
            ) {
                if
                    let lastOpened,
                    let lastUpdated,
                    let lastUpdatedChapters,
                    let dateAdded
                {
                    libraryObject.lastOpened = lastOpened
                    libraryObject.lastUpdated = lastUpdated
                    libraryObject.lastUpdatedChapters = lastUpdatedChapters
                    libraryObject.lastChapter = lastChapter
                    libraryObject.lastRead = lastRead
                    libraryObject.dateAdded = dateAdded
                }
            }

            for item in trackItems {
                CoreDataManager.shared.createTrack(
                    id: item.id,
                    trackerId: item.trackerId,
                    mangaId: item.mangaId,
                    title: item.title,
                    context: context
                )
            }

            for category in categories {
                let hasCategory = CoreDataManager.shared.hasCategory(title: category, context: context)
                if !hasCategory {
                    CoreDataManager.shared.createCategory(title: category, context: context)
                }
            }
            CoreDataManager.shared.addCategoriesToManga(
                mangaId: newManga.identifier,
                categories: categories,
                context: context
            )

            do {
                try context.save()
            } catch {
                LogManager.logger.error(
                    "MangaManager.restoreToLibrary: \(error.localizedDescription)")
            }
        }
        if downloadAhead > 0 {
            DownloadAheadSetting.set(downloadAhead, for: newManga.identifier)
        }
    }

    static func shouldAskForCategories() async -> Bool {
        let categories = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getCategoryTitles(sorted: false, context: context)
        }
        guard !categories.isEmpty else { return false }
        if
            let defaultCategory = AppSettings.library.defaultCategory.get(),
            defaultCategory == "none" || categories.contains(defaultCategory)
        {
            return false
        }
        return true
    }
}

// MARK: - Category Managing
extension MangaManager {
    func setCategories(mangaId: MangaIdentifier, categories: [String]) async {
        await CoreDataManager.shared.setMangaCategories(
            mangaId: mangaId,
            categories: categories
        )
        NotificationCenter.default.post(name: .updateMangaCategories, object: MangaInfo(id: mangaId))
    }
}

// MARK: - Library Updating
extension MangaManager {
    nonisolated func register() {
#if !targetEnvironment(simulator)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { @Sendable [weak self] task in
            guard let self else { return }

            task.expirationHandler = {
                Task {
                    await self.libraryRefreshTask?.cancel()
                }
                task.setTaskCompleted(success: false)
            }

            Task { @Sendable in
                await self.refreshLibrary(category: self.targetCategory, task: task as? ProgressReporting)

                task.setTaskCompleted(success: true)
            }
        }
#endif
    }

    func scheduleLibraryRefresh() {
        let lastUpdated = AppSettings.library.lastUpdated.get()
        let interval: Double = switch AppSettings.library.updateInterval.get() {
            case "12hours": 43200
            case "daily": 86400
            case "2days": 172800
            case "weekly": 604800
            default: 0
        }
        guard interval > 0 else {
#if !targetEnvironment(simulator)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
#endif
            return
        }
        let nextUpdateTime = lastUpdated + interval

        if nextUpdateTime < Date.now {
            guard !AppSettings.flags.libraryRefreshInProgress.get() else { return }
            // interval time has passed, refresh now
            Task {
                await refreshLibrary()
            }
        } else {
#if !targetEnvironment(simulator)
            // schedule task for the future
            let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
            request.earliestBeginDate = nextUpdateTime
            request.requiresExternalPower = false
            request.requiresNetworkConnectivity = true

            Task {
                do {
                    try await BGTaskScheduler.shared.submit(request: request)
                } catch {
                    LogManager.logger.error("Could not schedule library refresh: \(error)")
                }
            }
#endif
        }
    }

    func backgroundRefreshLibrary(category: String? = nil, skipReachabilityCheck: Bool = false) async {
        targetCategory = category
        self.skipReachabilityCheck = skipReachabilityCheck

#if !targetEnvironment(simulator)
        if #available(iOS 26.0, *), AppSettings.library.backgroundRefresh.get(), !ProcessInfo.processInfo.isMacCatalystApp {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.taskIdentifier,
                title: NSLocalizedString("REFRESHING_LIBRARY"),
                subtitle: NSLocalizedString("PROCESSING_ENTRIES")
            )
            do {
                try await BGTaskScheduler.shared.submit(request: request)
                return
            } catch {
                LogManager.logger.error("Failed to start background library refresh: \(error)")
            }
        }
#endif

        await refreshLibrary(category: category)
    }

    /// Refresh manga objects in library.
    func refreshLibrary(
        category: String? = nil,
        forceAll: Bool = false,
        task: (ProgressReporting & Sendable)? = nil
    ) async {
        let tabController = await UIApplication.shared.firstKeyWindow?.rootViewController as? TabBarController

        if libraryRefreshTask != nil {
            // wait for already running library refresh
            await libraryRefreshTask?.value
        } else {
            // spawn new library refresh
            AppSettings.flags.libraryRefreshInProgress.set(true)
            libraryRefreshTask = Task {
                await doLibraryRefresh(
                    category: category,
                    skipReachabilityCheck: skipReachabilityCheck,
                    forceAll: forceAll,
                    task: task,
                    refreshStarted: {
                        await tabController?.showLibraryRefreshView()

                        self.onLibraryRefreshProgress = { progress in
                            tabController?.setLibraryRefreshProgress(Float(progress.fractionCompleted))
                            task?.progress.totalUnitCount = progress.totalUnitCount
                            task?.progress.completedUnitCount = progress.completedUnitCount
                            if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
                                task.updateTitle(
                                    NSLocalizedString("REFRESHING_LIBRARY"),
                                    subtitle: String(format: NSLocalizedString("%i_OF_%i"), progress.completedUnitCount, progress.totalUnitCount)
                                )
                            }
                        }
                    }
                )
                libraryRefreshTask = nil
                AppSettings.flags.libraryRefreshInProgress.reset()
            }
            await libraryRefreshTask?.value
        }

        self.targetCategory = nil
        self.skipReachabilityCheck = false

        // wait 0.5s for final progress animation to complete
        try? await Task.sleep(nanoseconds: 500_000_000)
        await tabController?.hideAccessoryView()

        NotificationCenter.default.post(name: .updateLibrary, object: nil)

        scheduleLibraryRefresh()
    }

    /// Check if a manga should skip updating based on skip options.
    private nonisolated func shouldSkip(
        manga: Manga,
        options: [String],
        excludedCategories: [String] = [],
        loadedSourceKeys: Set<String>,
        context: NSManagedObjectContext
    ) -> Bool {
        // update strategy is never
        if manga.updateStrategy == .never {
            return true
        }
        // next update time hasn't been reached
        if let nextUpdateTime = manga.nextUpdateTime {
            if nextUpdateTime > Date() {
                return true
            }
        }
        // source is missing
        if !loadedSourceKeys.contains(manga.sourceId) {
            return true
        }
        // completed
        if options.contains("completed") && manga.status == .completed {
            return true
        }
        // has unread chapters
        if options.contains("hasUnread") && CoreDataManager.shared.unreadCount(
            mangaId: manga.identifier,
            lang: manga.langFilter,
            scanlators: manga.scanlatorFilter,
            context: context
        ) > 0 {
            return true
        }
        // has no read chapters
        if options.contains("notStarted") && CoreDataManager.shared.readCount(
            mangaId: manga.identifier,
            lang: manga.langFilter,
            scanlators: manga.scanlatorFilter,
            context: context
        ) == 0 {
            return true
        }

        if !excludedCategories.isEmpty {
            // check if excluded via category
            let categories = CoreDataManager.shared.getCategories(
                mangaId: manga.identifier,
                context: context
            ).compactMap { $0.title }

            if !categories.isEmpty {
                if excludedCategories.contains(where: categories.contains) {
                    return true
                }
            }
        }

        return false
    }

    private func doLibraryRefresh(
        category: String?,
        skipReachabilityCheck: Bool,
        forceAll: Bool,
        task: ProgressReporting? = nil,
        refreshStarted: (() async -> Void)? = nil
    ) async {
        // make sure user agent and sources have loaded before doing library refresh
        _ = await UserAgentProvider.shared.getUserAgent()
        await SourceManager.shared.waitForSourcesLoad()

        // process failed tracker updates first
        await TrackerManager.shared.processPendingUpdates()

        // fetch all library items from db
        let allManga = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(category: category, context: context).compactMap { $0.manga?.toManga() }
        }

        // ensure there are manga to update
        guard !allManga.isEmpty else {
            return
        }

        // check if connected to wi-fi
        if
            !skipReachabilityCheck,
            AppSettings.library.updateOnlyOnWifi.get(),
            Reachability.getConnectionType() != .wifi
        {
            return
        }

        let skipOptions = forceAll ? [] : AppSettings.library.skipTitles.get()
        let excludedCategories = forceAll ? [] : AppSettings.library.excludedUpdateCategories.get().filter { $0 != category }
        let updateMetadata = forceAll || AppSettings.library.refreshMetadata.get()

        await refreshStarted?()

        let allLoadedSourceKeys = await Set(SourceManager.shared.getLoadedSources().map { $0.key })

        // filter items that we should skip
        let filteredManga = await CoreDataManager.shared.container.performBackgroundTask { context in
            allManga.filter { manga in
                !self.shouldSkip(
                    manga: manga,
                    options: skipOptions,
                    excludedCategories: excludedCategories,
                    loadedSourceKeys: allLoadedSourceKeys,
                    context: context
                )
            }
        }

        let total = filteredManga.count
        var completed = 0

        let isBackground = await UIApplication.shared.applicationState != .active
        let notificationsEnabled = isBackground && NotificationManager.shared.isEnabled()
        var pendingNotifications: [NotificationManager.NewChaptersSummary] = []

        let newDetails = await {
            var results: [Int: AidokuRunner.Manga] = [:]
            let progress = Progress(totalUnitCount: Int64(total))

            for manga in filteredManga {
                guard !Task.isCancelled else { return results }

                guard
                    let newManga = try? await SourceManager.shared.source(for: manga.sourceId)?
                        .getMangaUpdate(manga: manga.toNew(), needsDetails: updateMetadata, needsChapters: true)
                else {
                    completed += 1
                    progress.completedUnitCount = Int64(completed)
                    updateLibraryRefreshProgress(progress)
                    continue
                }

                if updateMetadata {
                    results[manga.hashValue] = newManga
                }

                let mangaId = manga.identifier
                let mangaTitle = manga.title

                let (summary, foundNewChapters) = await CoreDataManager.shared.container.performBackgroundTask {
                    context -> (NotificationManager.NewChaptersSummary?, Bool) in
                    guard
                        let libraryObject = CoreDataManager.shared.getLibraryManga(
                            mangaId: mangaId,
                            context: context
                        ),
                        let mangaObject = libraryObject.manga
                    else {
                        return (nil, false)
                    }

                    // update details
                    if updateMetadata {
                        mangaObject.load(from: newManga)
                    }

                    // update chapters
                    guard let chapters = newManga.chapters, !chapters.isEmpty else { return (nil, false) }

                    let newChapters = CoreDataManager.shared.setChapters(
                        chapters,
                        mangaId: mangaId,
                        context: context
                    )
                    var notifiableCount = 0
                    if !newChapters.isEmpty {
                        // add manga updates
                        let scanlatorFilter = mangaObject.scanlatorFilter ?? []
                        for chapter in newChapters
                        where
                            mangaObject.langFilter != nil ? chapter.lang == mangaObject.langFilter : true
                            && !scanlatorFilter.isEmpty ? scanlatorFilter.contains(chapter.scanlator ?? "") : true
                        {
                            CoreDataManager.shared.createMangaUpdate(
                                mangaId: mangaId,
                                chapterObject: chapter,
                                context: context
                            )
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

                    guard notifiableCount > 0 else { return (nil, !newChapters.isEmpty) }
                    let title = mangaObject.title.isEmpty ? (mangaTitle ?? "") : mangaObject.title
                    return (NotificationManager.NewChaptersSummary(
                        mangaIdentifier: mangaId,
                        mangaTitle: title,
                        chapterCount: notifiableCount
                    ), true)
                }

                if foundNewChapters {
                    // «descarga adelantada»: queue the new chapters that fall in the window
                    await DownloadManager.shared.ensureAheadDownloaded(manga: manga.toNew())
                }

                if notificationsEnabled, let summary {
                    pendingNotifications.append(summary)
                }

                completed += 1
                progress.completedUnitCount = Int64(completed)
                updateLibraryRefreshProgress(progress)
            }

            return results
        }()

        if notificationsEnabled, !pendingNotifications.isEmpty {
            await NotificationManager.shared.notifyNewChapters(pendingNotifications)
        }

        if updateMetadata {
            for mangaItem in filteredManga {
                guard let newInfo = newDetails[mangaItem.hashValue] else { continue }
                mangaItem.load(from: newInfo.toOld())
            }
        }

        AppSettings.library.lastUpdated.set(Date.now)
    }

    private func updateLibraryRefreshProgress(_ progress: Progress) {
        libraryRefreshProgressTask?.cancel()
        libraryRefreshProgressTask = Task {
            // buffer progress updates by 100ms
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await onLibraryRefreshProgress?(progress)
        }
    }
}

// MARK: - Detail Editing
extension MangaManager {
    // sets uploaded cover image and returns the new cover url
    func setCover(manga: AidokuRunner.Manga, cover: PlatformImage) async -> String? {
        if manga.isLocal() {
            return await LocalFileManager.shared.setCover(for: manga.key, image: cover)
        }

        // upload cover image to Documents/Covers/id.png
        let documentsDirectory = FileManager.default.documentDirectory
        let targetDirectory = documentsDirectory.appendingPathComponent("Covers")
        let ext = if #available(iOS 17.0, *) {
            "heic"
        } else {
            "png"
        }
        var targetUrl = targetDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        while targetUrl.exists {
            targetUrl = targetDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        }
        targetDirectory.createDirectory()
        do {
            let data = if #available(iOS 17.0, *) {
                cover.heicData()
            } else {
                cover.pngData()
            }
            try data?.write(to: targetUrl)
        } catch {
            LogManager.logger.error("MangaManager.setMangaCover: \(error.localizedDescription)")
            return nil
        }

        // set cover in coredata
        let coverUrl = "aidoku-image:///Covers/\(targetUrl.lastPathComponent)"
        await CoreDataManager.shared.setCover(
            mangaId: manga.identifier,
            coverUrl: coverUrl
        )

        return coverUrl
    }

    func resetCover(manga: AidokuRunner.Manga) async -> String? {
        guard let source = await SourceManager.shared.source(for: manga.sourceKey) else { return nil }

        // fetch new manga details (for cover)
        let newManga = try? await source.getMangaUpdate(
            manga: manga,
            needsDetails: true,
            needsChapters: false
        )

        guard let cover = newManga?.cover else { return nil }

        // set new cover and get old cover url
        let originalCover = await CoreDataManager.shared.setCover(
            mangaId: manga.identifier,
            coverUrl: cover,
            original: true
        )

        // if the original cover is an aidoku image, remove it
        if originalCover != cover, let originalCover, let url = URL(string: originalCover)?.toAidokuFileUrl() {
            url.removeItem()
        }

        return cover
    }
}

// MARK: Migration
extension MangaManager {
    /// The old choices (Copy / Migrate / Migrate and keep history), carrying everything over.
    func migrate(
        copy: Bool,
        forceRemoveFromLibrary: Bool = false,
        fromSeries: [AidokuRunner.Manga],
        toSeries: [MangaIdentifier: AidokuRunner.Manga?],
        withChapters: [MangaIdentifier: [AidokuRunner.Chapter]] = [:],
        progressReport: (@Sendable (Float) -> Void)? = nil
    ) async {
        await migrate(
            options: .init(copy: copy, forceRemoveFromLibrary: forceRemoveFromLibrary),
            fromSeries: fromSeries,
            toSeries: toSeries,
            withChapters: withChapters,
            progressReport: progressReport
        )
    }

    func migrate(
        options: MigrationOptions,
        fromSeries: [AidokuRunner.Manga],
        toSeries: [MangaIdentifier: AidokuRunner.Manga?],
        withChapters: [MangaIdentifier: [AidokuRunner.Chapter]] = [:],
        environment: MigrationEnvironment = .live,
        progressReport: (@Sendable (Float) -> Void)? = nil
    ) async {
        let newDetails = await fetchNewDetails(
            fromSeries: fromSeries,
            toSeries: toSeries,
            withChapters: withChapters,
            progressReport: { counter in
                if let progressReport {
                    progressReport(Float(counter) / Float(fromSeries.count * 2))
                }
            }
        )

        await withTaskGroup(of: (from: AidokuRunner.Manga, to: AidokuRunner.Manga)?.self) { group in
            let batchSize = 10
            var counter = fromSeries.count

            for i in stride(from: 0, to: fromSeries.count, by: batchSize) {
                let batch = Array(fromSeries[i..<min(i + batchSize, fromSeries.count)])

                for oldManga in batch {
                    group.addTask {
                        guard
                            let details = newDetails[oldManga.key]
                        else { return nil }

                        let newManga = details.0
                        let newChapters = details.1

                        return await Self.migrate(
                            options: options,
                            from: oldManga,
                            to: newManga,
                            withChapters: newChapters,
                            environment: environment
                        )
                    }
                }

                for await result in group {
                    counter += 1
                    if let progressReport {
                        progressReport(Float(counter) / Float(fromSeries.count * 2))
                    }
                    if let result {
                        if environment.bindEnhancedTrackers {
                            await TrackerManager.shared.bindEnhancedTrackers(manga: result.to)
                        }
                        if !options.keepOriginal {
                            NotificationCenter.default.post(name: .migratedManga, object: result)
                        }
                    }
                }
            }
        }
    }

    /// One entry. Internal for tests (no source needed: the new details and chapters come in).
    static func migrate(
        options: MigrationOptions,
        from oldManga: AidokuRunner.Manga,
        to newManga: AidokuRunner.Manga,
        withChapters newChapters: [AidokuRunner.Chapter],
        environment: MigrationEnvironment = .live
    ) async -> (AidokuRunner.Manga, AidokuRunner.Manga)? {
        // keep the original = add the new entry next to it (the old «copy»); otherwise replace it
        let copy = options.keepOriginal
        // migrate settings
        if let readingMode = UserDefaults.standard.string(forKey: "Reader.readingMode.\(oldManga.identifier)") {
            UserDefaults.standard.set(readingMode, forKey: "Reader.readingMode.\(newManga.identifier)")
            if !copy {
                UserDefaults.standard.removeObject(forKey: "Reader.readingMode.\(oldManga.identifier)")
            }
        }
        // was the new entry already in the library (it keeps its own categories)
        var newWasInLibrary = false
        // add new item to library if copying
        if copy {
            let inLibrary = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
                let storedNewManga = CoreDataManager.shared.getManga(
                    mangaId: newManga.identifier,
                    context: context
                )
                guard let storedNewManga else {
                    return false // add to library
                }
                // update details
                storedNewManga.load(from: newManga)
                // update chapters
                CoreDataManager.shared.setChapters(
                    newChapters,
                    mangaId: newManga.identifier,
                    context: context
                )
                return true
            }
            newWasInLibrary = inLibrary
            if !inLibrary {
                // the enhanced trackers are bound once the history is carried over
                await MangaManager.shared.addToLibrary(
                    manga: newManga,
                    chapters: newChapters,
                    bindTrackers: false
                )
            }
        }

        // Suwayomi server (JoTa): the new server manga is tracked by its own id and only it stays in the
        // server library when the old one leaves the Aidoku library
        let suwayomiTracker = environment.suwayomiTracker
        let suwayomiPlan = suwayomiTracker.map {
            SuwayomiMigrationPlan.make(
                old: oldManga.identifier,
                new: newManga.identifier,
                oldIsServer: $0.canRegister(mangaId: oldManga.identifier),
                newIsServer: $0.canRegister(mangaId: newManga.identifier),
                oldLeavesLibrary: !copy
            )
        } ?? .none
        let suwayomiTrackerId = suwayomiTracker?.id

        // migrate/copy data
        let result: (AidokuRunner.Manga, AidokuRunner.Manga)? = await CoreDataManager.shared.container.performBackgroundTask { context in
            do {
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
                for completed in options.readChapters ? historyPlan.completed : [] {
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
                    if let suwayomiTrackerId, item.trackerId == suwayomiTrackerId {
                        // the server tracks each manga by its own id: move it to the new manga's id
                        let newHasTrack = CoreDataManager.shared.hasTrack(
                            trackerId: suwayomiTrackerId,
                            mangaId: newManga.identifier,
                            context: context
                        )
                        if let newTrackId = suwayomiPlan.newTrackId {
                            if !copy {
                                if newHasTrack {
                                    context.delete(item)
                                } else {
                                    item.id = newTrackId
                                    item.sourceId = newManga.sourceKey
                                    item.mangaId = newManga.key
                                }
                            } else if !newHasTrack {
                                CoreDataManager.shared.createTrack(
                                    id: newTrackId,
                                    trackerId: suwayomiTrackerId,
                                    mangaId: newManga.identifier,
                                    title: item.title,
                                    context: context
                                )
                            }
                        } else if !copy && newManga.identifier != oldManga.identifier {
                            context.delete(item) // the new one isn't a server manga: nothing to point at
                        }
                        continue
                    }
                    guard
                        options.tracking, // the user's trackers only if asked
                        let trackId = item.id,
                        let trackerId = item.trackerId,
                        !CoreDataManager.shared.hasTrack(
                            trackerId: trackerId,
                            mangaId: newManga.identifier,
                            context: context
                        ),
                        let tracker = environment.trackerLookup(trackerId),
                        tracker.canRegister(mangaId: newManga.identifier)
                    else {
                        if !copy && newManga.identifier != oldManga.identifier {
                            context.delete(item)
                        }
                        continue
                    }

                    if copy {
                        CoreDataManager.shared.createTrack(
                            id: trackId,
                            trackerId: trackerId,
                            mangaId: newManga.identifier,
                            title: item.title,
                            context: context
                        )
                    } else {
                        item.sourceId = newManga.sourceKey
                        item.mangaId = newManga.key
                    }
                }

                try context.save()

                return (from: oldManga, to: newManga)
            } catch {
                LogManager.logger.error("Error migrating manga \(oldManga.key): \(error)")
                return nil
            }
        }

        if result != nil {
            DownloadAheadSetting.migrate(from: oldManga.identifier, to: newManga.identifier, copy: copy)
        }

        if result != nil, let suwayomiTracker, suwayomiPlan != .none {
            // best effort on the server: failures are logged and don't undo the migration on the device
            let newId = newManga.identifier
            // without the read chapters, the server gets no last read chapter
            let highestRead = options.readChapters ? await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getHighestReadNumber(mangaId: newId, context: context)
            } : nil
            await suwayomiTracker.applyMigration(suwayomiPlan, old: oldManga.identifier, highestChapterRead: highestRead)
        }

        // the original's downloads, only once the migration went well
        if options.shouldDeleteDownloads(old: oldManga.identifier, new: newManga.identifier, succeeded: result != nil) {
            await environment.deleteDownloads(oldManga.identifier)
        }

        if copy && result != nil {
            await MainActor.run {
                NotificationCenter.default.post(name: .updateLibrary, object: nil)
            }
        }

        return result
    }

    private func fetchNewDetails(
        fromSeries: [AidokuRunner.Manga],
        toSeries: [MangaIdentifier: AidokuRunner.Manga?],
        withChapters: [MangaIdentifier: [AidokuRunner.Chapter]],
        progressReport: (Int) -> Void
    ) async -> [String: (AidokuRunner.Manga, [AidokuRunner.Chapter])] {
        await withTaskGroup(
            of: (String, AidokuRunner.Manga, [AidokuRunner.Chapter])?.self,
            returning: [String: (AidokuRunner.Manga, [AidokuRunner.Chapter])].self
        ) { group in
            let batchSize = 5
            var ret: [String: (AidokuRunner.Manga, [AidokuRunner.Chapter])] = [:]
            var counter = 0

            for i in stride(from: 0, to: fromSeries.count, by: batchSize) {
                let batch = Array(fromSeries[i..<min(i + batchSize, fromSeries.count)])

                for oldManga in batch {
                    group.addTask {
                        guard
                            let newManga = toSeries[oldManga.identifier],
                            let newManga,
                            let source = await SourceManager.shared.source(for: newManga.sourceKey)
                        else { return nil }

                        let newChapters = withChapters[oldManga.identifier]

                        let updatedManga = try? await source.getMangaUpdate(
                            manga: newManga,
                            needsDetails: true,
                            needsChapters: newChapters == nil
                        )

                        let mangaDetails = updatedManga ?? newManga
                        let chapters = newChapters ?? updatedManga?.chapters ?? []

                        return (oldManga.key, mangaDetails, chapters)
                    }
                }

                // wait for all results in batch to finish before continuing
                for await result in group {
                    counter += 1
                    progressReport(counter)
                    if let result {
                        ret[result.0] = (result.1, result.2)
                    }
                }
            }

            return ret
        }
    }
}
