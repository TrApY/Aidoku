//
//  TrackerManager.swift
//  Aidoku
//
//  Created by Skitty on 6/14/22.
//

import AidokuRunner
import CoreData
import Foundation

/// An interface to interact with title tracking services.
actor TrackerManager {
    /// The shared tracker mangaer instance.
    static let shared = TrackerManager()

    /// An instance of the Komga tracker.
    static let komga = KomgaTracker()
    /// An instance of the Komga tracker.
    static let kavita = KavitaTracker()
    /// An instance of the Suwayomi tracker.
    static let suwayomi = SuwayomiTracker()
    /// An instance of the AniList tracker.
    static let anilist = AniListTracker()
    /// An instance of the MyAnimeList tracker.
    static let myanimelist = MyAnimeListTracker()
    /// An instance of the MangaBaka tracker.
    static let mangabaka = MangaBakaTracker()
    /// An instance of the Shikimori tracker.
    static let shikimori = ShikimoriTracker()
    /// An instance of the Bangumi tracker.
    static let bangumi = BangumiTracker()

    /// An array of the available trackers.
    static let trackers: [Tracker] = [komga, kavita, suwayomi, anilist, myanimelist, mangabaka, shikimori, bangumi]

    /// A boolean indicating if there is a tracker that is currently logged in.
    static var hasAvailableTrackers: Bool {
        Self.trackers.filter { !($0 is EnhancedTracker) }.contains { $0.isLoggedIn }
    }

    /// Get the instance of the tracker with the specified id.
    static func getTracker(id: String) -> Tracker? {
        Self.trackers.first { $0.id == id }
    }

    struct TrackingState: Codable {
        var pendingPageUpdates: [PageTrackUpdate] = []
    }
    private var trackingState: TrackingState
    private var pageUpdateTask: Task<(), Never>?
    /// Where pending page updates are saved (nil: not saved, for tests).
    private let stateKey: String?
    private let pageTrackerLookup: @Sendable (String) -> Tracker?

    init(
        stateKey: String? = "Tracker.pageTrackingState",
        pageTrackerLookup: @escaping @Sendable (String) -> Tracker? = { TrackerManager.getTracker(id: $0) }
    ) {
        self.stateKey = stateKey
        self.pageTrackerLookup = pageTrackerLookup
        self.trackingState = stateKey.flatMap { UserDefaults.standard.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode(TrackingState.self, from: $0) } ?? .init()
    }

    /// Send chapter read update to logged in trackers.
    func setCompleted(mangaId: MangaIdentifier, chapter: AidokuRunner.Chapter, skipTracker: Tracker? = nil) async {
        let chapterNum = chapter.chapterNumber
        let volumeNum = chapter.volumeNumber.flatMap { Int(floor($0)) }
        guard chapterNum != nil || volumeNum != nil else { return }

        let key = "Manga.chapterDisplayMode.\(mangaId)"
        let displayMode = ChapterTitleDisplayMode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .default

        let trackItems: [TrackItem] = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            CoreDataManager.shared.getTracks(mangaId: mangaId, context: context).map { $0.toItem() }
        }

        for item in trackItems {
            guard
                skipTracker?.id != item.trackerId,
                let tracker = Self.getTracker(id: item.trackerId),
                !(tracker is PageTracker),
                let state = try? await tracker.getState(trackId: item.id)
            else { continue }

            // Check if we need to update based on chapter display mode
            var shouldUpdate = false
            if displayMode == .chapter {
                // Chapter mode: check chapter progress, or volume progress if no chapter
                let hasChapterProgress = chapterNum != nil && (state.lastReadChapter ?? 0) < chapterNum!
                let hasVolumeProgress = volumeNum != nil && (state.lastReadChapter ?? 0) < Float(volumeNum!)
                shouldUpdate = hasChapterProgress || hasVolumeProgress
            } else if displayMode == .volume {
                // Volume mode: check volume progress, or chapter progress if no volume
                let hasChapterProgress = chapterNum != nil && (state.lastReadVolume ?? 0) < Int(floor(chapterNum!))
                let hasVolumeProgress = volumeNum != nil && (state.lastReadVolume ?? 0) < volumeNum!
                shouldUpdate = hasChapterProgress || hasVolumeProgress
            } else {
                // Default mode: check both chapter and volume progress
                let hasChapterProgress = chapterNum != nil && (state.lastReadChapter ?? 0) < chapterNum!
                let hasVolumeProgress = volumeNum != nil && (state.lastReadVolume ?? 0) < volumeNum!
                shouldUpdate = hasChapterProgress || hasVolumeProgress
            }
            guard shouldUpdate else { continue }

            var update = TrackUpdate()

            // update last read chapter and volume based on mode
            if displayMode == .chapter {
                // chapter mode: only update chapter, don't update volume
                if let chapterNum, chapterNum > 0 {
                    let newChapterNumber = Self.applyChapterOffset(
                        to: chapterNum,
                        offset: item.chapterOffset,
                        maxChapters: state.totalChapters
                    )
                    if state.lastReadChapter ?? 0 < newChapterNumber {
                        update.lastReadChapter = newChapterNumber
                    }
                } else if let volumeNum {
                    // no chapter metadata, use volume number as chapter
                    let chapterFromVolume = Self.applyChapterOffset(
                        to: Float(volumeNum),
                        offset: item.chapterOffset,
                        maxChapters: state.totalChapters
                    )
                    if chapterFromVolume > state.lastReadChapter ?? 0 {
                        update.lastReadChapter = chapterFromVolume
                    }
                }
            } else if displayMode == .volume {
                // volume mode: only update volume, don't update chapter
                if let volumeNum, volumeNum > 0 && state.lastReadVolume ?? 0 < volumeNum {
                    update.lastReadVolume = volumeNum
                } else if let chapterNum {
                    // no volume metadata, use chapter number as volume
                    let volumeFromChapter = Int(floor(chapterNum))
                    if volumeFromChapter > state.lastReadVolume ?? 0 {
                        update.lastReadVolume = volumeFromChapter
                    }
                }
            } else {
                // default mode: update both chapter and volume if available
                if let chapterNum, chapterNum > 0 {
                    let newChapterNumber = Self.applyChapterOffset(
                        to: chapterNum,
                        offset: item.chapterOffset,
                        maxChapters: state.totalChapters
                    )
                    if state.lastReadChapter ?? 0 < newChapterNumber {
                        update.lastReadChapter = newChapterNumber
                    }
                }
                if let volumeNum, volumeNum > 0 && state.lastReadVolume ?? 0 < volumeNum {
                    update.lastReadVolume = volumeNum
                }
            }

            // update reading state
            let readLastChapter = if
                chapterNum != nil,
                let totalChapters = state.totalChapters,
                let lastReadChapter = state.lastReadChapter
            {
                totalChapters == Int(floor(lastReadChapter))
            } else if (chapterNum == nil || displayMode == .volume) && update.lastReadVolume != nil {
                update.lastReadVolume == state.totalVolumes
            } else {
                false
            }
            if readLastChapter {
                if state.finishReadDate == nil {
                    update.finishReadDate = Date()
                }
                update.status = .completed
            } else if state.status != .reading && state.status != .rereading {
                // if there's no start date, and the status is planning or null, set it to current date
                if state.startReadDate == nil && state.status == nil || state.status == .planning {
                    update.startReadDate = Date()
                }
                update.status = state.status == .completed ? .rereading : .reading
            }

            do {
                try await tracker.update(trackId: item.id, update: update)
            } catch {
                LogManager.logger.error("Failed to set tracker chapter as completed (\(tracker.id)): \(error)")
            }
        }
    }

    /// Set the page progress for trackers that support it.
    func setProgress(mangaId: MangaIdentifier, chapter: AidokuRunner.Chapter, progress: ChapterReadProgress) async {
        await setProgress(mangaId: mangaId, chapters: [chapter], progress: progress)
    }

    func setProgress(mangaId: MangaIdentifier, chapters: [AidokuRunner.Chapter], progress: ChapterReadProgress) async {
        let trackItems: [TrackItem] = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getTracks(
                mangaId: mangaId,
                context: context
            ).map { $0.toItem() }
        }

        var newUpdates: [PageTrackUpdate] = []

        for item in trackItems {
            guard let tracker = Self.getTracker(id: item.trackerId) as? PageTracker else {
                continue
            }
            for chapter in chapters {
                newUpdates.append(.init(
                    trackerId: tracker.id,
                    trackId: item.id,
                    chapterId: .init(
                        sourceKey: mangaId.sourceKey,
                        mangaKey: mangaId.mangaKey,
                        chapterKey: chapter.key
                    ),
                    progress: progress
                ))
            }
        }

        queuePageUpdates(newUpdates)
        await processPendingUpdates()
    }

    /// Register a new track item to a manga and save to the data store.
    func register(tracker: Tracker, manga: AidokuRunner.Manga, item: TrackSearchItem) async {
        let mangaId = manga.identifier
        let (highestReadNumber, earliestReadDate) = await CoreDataManager.shared.container.performBackgroundTask { context in
            (
                CoreDataManager.shared.getHighestReadNumber(
                    mangaId: mangaId,
                    context: context
                ),
                CoreDataManager.shared.getEarliestReadDate(
                    mangaId: mangaId,
                    context: context
                )
            )
        }
        do {
            let id = try await tracker.register(
                trackId: item.id,
                highestChapterRead: highestReadNumber,
                earliestReadDate: earliestReadDate
            )
            let trackItem = TrackItem(
                id: id ?? item.id,
                trackerId: tracker.id,
                mangaId: mangaId,
                title: item.title ?? manga.title,
                chapterOffset: 0
            )
            await TrackerManager.shared.saveTrackItem(item: trackItem)

            // Sync progress from tracker if enabled or is enhanced tracker
            if AppSettings.tracking.autoSyncFromTracker.get() || (tracker is EnhancedTracker) || (tracker is PageTracker) {
                await syncProgressFromTracker(tracker: tracker, trackItem: trackItem, manga: manga)
            } else {
                NotificationCenter.default.post(name: .syncTrackItem, object: trackItem)
            }
        } catch {
            LogManager.logger.error("Failed to register tracker \(tracker.id): \(error)")
        }
    }

    /// Saves a TrackItem to the data store.
    private func saveTrackItem(item: TrackItem) async {
        await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            CoreDataManager.shared.createTrack(
                id: item.id,
                trackerId: item.trackerId,
                mangaId: item.mangaId,
                title: item.title,
                chapterOffset: item.chapterOffset,
                context: context
            )
            do {
                try context.save()
            } catch {
                LogManager.logger.error("TrackManager.saveTrackItem(item:): \(error)")
            }
        }
        NotificationCenter.default.post(name: .updateTrackers, object: nil)
        NotificationCenter.default.post(name: .trackItemAdded, object: item)
    }

    /// Removes the TrackItem from the data store.
    func removeTrackItem(item: TrackItem) async {
        await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            self.removeTrackItem(item: item, context: context)
        }
    }

    /// Sets the chapter offset for a track item.
    func setTrackChapterOffset(item: TrackItem, chapterOffset: Int) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.setTrackChapterOffset(
                trackerId: item.trackerId,
                mangaId: item.mangaId,
                chapterOffset: chapterOffset,
                context: context
            )
            do {
                try context.save()
            } catch {
                LogManager.logger.error("TrackManager.setTrackChapterOffset(item:chapterOffset:): \(error)")
            }
        }
        NotificationCenter.default.post(name: .updateTrackers, object: nil)
    }

    nonisolated func removeTrackItem(item: TrackItem, context: NSManagedObjectContext) {
        CoreDataManager.shared.removeTrack(
            trackerId: item.trackerId,
            mangaId: item.mangaId,
            context: context
        )
        do {
            try context.save()
        } catch {
            LogManager.logger.error("TrackManager.removeTrackItem(item:): \(error)")
        }
        NotificationCenter.default.post(name: .updateTrackers, object: nil)
    }

    /// Checks if a manga is being tracked
    @MainActor
    func isTracking(mangaId: MangaIdentifier) -> Bool {
        CoreDataManager.shared.hasTrack(mangaId: mangaId)
    }

    /// Checks if there is a tracker that can be added to the given manga.
    func hasAvailableTrackers(mangaId: MangaIdentifier) async -> Bool {
        for tracker in Self.trackers {
            let canRegister = tracker.canRegister(mangaId: mangaId)
            if canRegister {
                return true
            }
        }
        return false
    }

    /// Sync progress from tracker to local history.
    func syncProgressFromTracker(
        tracker: Tracker,
        trackItem: TrackItem,
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter]? = nil
    ) async {
        if tracker is PageTracker {
            await syncPageTrackerHistory(
                tracker: tracker,
                manga: manga,
                chapters: chapters
            )
        } else {
            let chaptersToMark = await getChaptersToSyncProgressFromTracker(
                tracker: tracker,
                trackItem: trackItem,
                manga: manga,
                chapters: chapters
            )
            if !chaptersToMark.isEmpty {
                await HistoryManager.shared.addHistory(
                    mangaId: manga.identifier,
                    chapters: chaptersToMark,
                    skipTracker: tracker,
                    reason: "tracker \(tracker.id) (último leído)"
                )
            }
        }
    }

    /// Sync progress with all linked trackers that support page progress.
    /// - trackerLookup, downloadAhead: injectable for tests. `downloadAhead` runs on its own (not awaited).
    func syncPageTrackerHistory(
        tracker: Tracker? = nil,
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter]? = nil,
        trackerLookup: (String) -> Tracker? = { TrackerManager.getTracker(id: $0) },
        downloadAhead: @escaping @Sendable (MangaIdentifier) async -> Void = {
            await DownloadManager.shared.ensureAheadDownloaded(mangaId: $0)
        }
    ) async {
        let chapters = if let chapters {
            chapters
        } else {
            await getChapters(manga: manga)
        }
        guard !chapters.isEmpty else { return }

        // fetch remote history from linked page trackers
        var result: [String: ChapterReadProgress] = [:]

        let trackItems: [TrackItem] = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getTracks(
                mangaId: manga.identifier,
                context: context
            ).map { $0.toItem() }
        }

        for item in trackItems {
            guard let targetTracker = trackerLookup(item.trackerId) as? PageTracker else { continue }
            if let tracker, targetTracker.id != tracker.id {
                continue // if a specific tracker is provided, only sync that one
            }
            do {
                let batchProgress = try await targetTracker.getProgress(trackId: item.id, chapters: chapters)
                if result.isEmpty {
                    result = batchProgress
                } else {
                    // merge with the existing progress map, keeping newest
                    for (chapterKey, progress) in batchProgress {
                        if let existing = result[chapterKey] {
                            // replace if the new date is higher, otherwise keep existing
                            if let existingDate = existing.date, let newDate = progress.date {
                                if newDate > existingDate {
                                    result[chapterKey] = progress
                                }
                            }
                        } else {
                            result[chapterKey] = progress
                        }
                    }
                }
            } catch {
                LogManager.logger.error("Failed to get tracker progress (\(targetTracker.id)): \(error)")
            }
        }

        guard !result.isEmpty else { return }
        let trackerIdsForJournal = trackItems.map(\.trackerId).joined(separator: ",")

        // create local history
        let (completed, progressed) = await CoreDataManager.shared.container.performBackgroundTask { [result] context in
            var completed: [String] = []
            var progressed: [String: Int] = [:]
            var journal: [(ChapterIdentifier, String)] = [] // written once saved (SUWA-12 H3)

            var lastRead = Date.distantPast

            for (chapterKey, progress) in result {
                let chapterId = ChapterIdentifier(
                    sourceKey: manga.sourceKey,
                    mangaKey: manga.key,
                    chapterKey: chapterKey
                )
                let existingHistory = CoreDataManager.shared.getHistory(
                    chapterId: chapterId,
                    context: context
                )
                // without a date from the tracker the local history can't be compared: it stays (SUWA-12 F);
                // a chapter with no local history still gets the tracker's
                if existingHistory != nil && progress.date == nil {
                    continue
                }
                if let existingDate = existingHistory?.dateRead, let newDate = progress.date, newDate <= existingDate {
                    // don't update if the existing history is newer than the tracker history
                    continue
                }
                // mark chapters as read
                if progress.completed {
                    if !(existingHistory?.completed ?? false) {
                        journal.append((
                            chapterId,
                            "fecha \(progress.date.map { "\($0)" } ?? "ninguna"), local \(existingHistory.map { "pág \($0.progress)/\($0.total)" } ?? "sin historial")"
                        ))
                        completed.append(chapterKey)
                        // without the server's date the manga isn't «read recently» (SUWA-12 H4)
                        let readDate = progress.date ?? Date.distantPast
                        lastRead = readDate > lastRead ? readDate : lastRead
                        CoreDataManager.shared.setCompleted(
                            chapterIds: [chapterId],
                            date: progress.date ?? Date(),
                            context: context
                        )
                    }
                } else if progress.page != 0 {
                    progressed[chapterKey] = progress.page
                    let readDate = progress.date ?? Date.now
                    lastRead = readDate > lastRead ? readDate : lastRead
                    CoreDataManager.shared.setProgress(
                        progress.page,
                        chapterId: chapterId,
                        dateRead: readDate,
                        completed: false,
                        context: context
                    )
                }
            }

            // mark manga as read only if history was updated, with a date
            if (!completed.isEmpty || !progressed.isEmpty) && lastRead > Date.distantPast {
                CoreDataManager.shared.setRead(
                    mangaId: manga.identifier,
                    date: lastRead,
                    context: context
                )
            }

            do {
                try context.save()
                for (chapterId, detail) in journal {
                    CompletionJournal.record(chapterId, reason: "sincronización \(trackerIdsForJournal)", detail: detail)
                }
            } catch {
                LogManager.logger.error("TrackerManager.syncPageTrackerHistory: \(error)")
            }

            return (completed, progressed)
        }

        // post notifications to update ui
        if !completed.isEmpty {
            NotificationCenter.default.post(
                name: .historyAdded,
                object: completed.map {
                    ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0)
                }
            )
        }
        for (chapterKey, page) in progressed {
            NotificationCenter.default.post(
                name: .historySet,
                object: (
                    ChapterIdentifier(
                        sourceKey: manga.sourceKey,
                        mangaKey: manga.key,
                        chapterKey: chapterKey
                    ),
                    page
                )
            )
        }
        // «descarga adelantada»: chapters read on another device move the window too (on its own: details,
        // refresh and other trackers don't wait for it)
        if !completed.isEmpty {
            let mangaId = manga.identifier
            Task {
                await downloadAhead(mangaId)
            }
        }
    }

    /// Add all applicable enhanced trackers to a given manga.
    func bindEnhancedTrackers(manga: AidokuRunner.Manga) async {
        for tracker in Self.trackers where tracker is EnhancedTracker {
            if tracker.canRegister(mangaId: manga.identifier) {
                let isTracking = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.hasTrack(
                        trackerId: tracker.id,
                        mangaId: manga.identifier,
                        context: context
                    )
                }
                guard !isTracking else { continue }
                do {
                    let items = try await tracker.search(for: manga, includeNsfw: true)
                    guard let item = items.first else {
                        LogManager.logger.error("Unable to find track item from tracker \(tracker.id)")
                        return
                    }
                    await TrackerManager.shared.register(tracker: tracker, manga: manga, item: item)
                } catch {
                    LogManager.logger.error("Unable to find track item from tracker \(tracker.id): \(error)")
                }
            }
        }
    }
}

extension TrackerManager {
    static func applyChapterOffset(to chapter: Float, offset: Int, maxChapters: Int?) -> Float {
        var adjusted = chapter + Float(offset)
        adjusted = max(0, adjusted)
        if let maxChapters {
            adjusted = min(adjusted, Float(maxChapters))
        }
        return adjusted
    }
}

extension TrackerManager {
    private func getChapters(manga: AidokuRunner.Manga) async -> [AidokuRunner.Chapter] {
        let inLibrary = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: context)
        }
        if inLibrary {
            // load data from db
            return await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getChapters(
                    mangaId: manga.identifier,
                    context: context
                ).map {
                    $0.toNewChapter()
                }
            }
        } else {
            return (try? await SourceManager.shared.source(for: manga.sourceKey)?.getMangaUpdate(
                manga: manga,
                needsDetails: false,
                needsChapters: true
            ).chapters) ?? []
        }
    }

    func getChaptersToSyncProgressFromTracker(
        tracker: Tracker,
        trackItem: TrackItem,
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter]? = nil,
        currentHighestRead: Float? = nil
    ) async -> [AidokuRunner.Chapter] {
        guard
            let state = try? await tracker.getState(trackId: trackItem.id),
            case let trackerLastReadChapter = state.lastReadChapter,
            case let trackerLastReadVolume = state.lastReadVolume,
            (trackerLastReadChapter ?? 0) > 0 || (trackerLastReadVolume ?? 0) > 0
        else {
            return []
        }

        let chapters = if let chapters {
            chapters
        } else {
            await getChapters(manga: manga)
        }
        guard !chapters.isEmpty else { return [] }

        let currentHighestRead = if let currentHighestRead {
            currentHighestRead
        } else {
            await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getHighestReadNumber(
                    mangaId: manga.identifier,
                    context: context
                ) ?? 0
            }
        }

        // Check for display mode
        let key = "Manga.chapterDisplayMode.\(manga.identifier)"
        let displayMode = ChapterTitleDisplayMode(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .default

        var chaptersToMark: [AidokuRunner.Chapter] = []

        // Determine what to sync based on tracker progress and forced mode
        if displayMode == .chapter {
            // Forced chapter mode: sync chapter progress
            if let trackerLastReadChapter {
                let offsetTrackerLastReadChapter = Self.applyChapterOffset(
                    to: trackerLastReadChapter,
                    offset: -trackItem.chapterOffset,
                    maxChapters: state.totalChapters
                )
                if offsetTrackerLastReadChapter > currentHighestRead {
                    chaptersToMark = chapters.filter { ($0.chapterNumber ?? $0.volumeNumber ?? 0) <= offsetTrackerLastReadChapter }
                }
            }
        } else if displayMode == .volume {
            // Forced volume mode: sync volume progress
            if let trackerLastReadVolume, trackerLastReadVolume > 0 && Float(trackerLastReadVolume) > currentHighestRead {
                chaptersToMark = chapters.filter { ($0.volumeNumber ?? $0.chapterNumber ?? 0) <= Float(trackerLastReadVolume) }
            }
        } else {
            // Default mode: sync both chapter and volume progress
            var checkedForChapters = false
            if let trackerLastReadChapter {
                let offsetTrackerLastReadChapter = Self.applyChapterOffset(
                    to: trackerLastReadChapter,
                    offset: -trackItem.chapterOffset,
                    maxChapters: state.totalChapters
                )
                if offsetTrackerLastReadChapter > currentHighestRead {
                    // find all chapters with a chapter number less than or equal to the last tracker chapter
                    chaptersToMark = chapters.filter {
                        // floor the chapter number so partial chapters are marked (e.g. 10.1 and 10.2 will be marked if the tracker is at 10)
                        if let chapter = $0.chapterNumber, floor(chapter) <= offsetTrackerLastReadChapter {
                            true
                        } else {
                            false
                        }
                    }
                    checkedForChapters = true
                }
            }
            // otherwise, if we didn't find any chapters, try using the volume number instead
            // note: ignores the case where we skipped checking chapters due to currentHighestRead <= trackerLastReadChapter (#753)
            let foundNoChapters = checkedForChapters && chaptersToMark.isEmpty
            if let trackerLastReadVolume, trackerLastReadVolume > 0 && (foundNoChapters || trackerLastReadChapter == nil) {
                // find all chapters with a volume number less than or equal to the last tracker volume
                chaptersToMark = chapters.filter {
                    if let volume = $0.volumeNumber, volume <= Float(trackerLastReadVolume) {
                        true
                    } else {
                        false
                    }
                }
            }
        }

        return chaptersToMark
    }
}

// MARK: Tracking State
extension TrackerManager {
    /// Pending updates after a batch was sent: `current` is the pending list now (it may have new updates
    /// queued while the batch was on the network), `sent` the batch, `failed` the ones of the batch to
    /// retry. Only what was sent leaves the list; a newer update for the same chapter wins over a retry.
    static func remainingPageUpdates(
        current: [PageTrackUpdate],
        sent: [PageTrackUpdate],
        failed: [PageTrackUpdate]
    ) -> [PageTrackUpdate] {
        func sameTarget(_ a: PageTrackUpdate, _ b: PageTrackUpdate) -> Bool {
            a.trackerId == b.trackerId && a.trackId == b.trackId && a.chapterId == b.chapterId
        }
        func same(_ a: PageTrackUpdate, _ b: PageTrackUpdate) -> Bool {
            sameTarget(a, b) && a.progress.completed == b.progress.completed && a.progress.page == b.progress.page
                && a.progress.date == b.progress.date && a.failCount == b.failCount
        }
        // what was queued meanwhile stays (anything not exactly an update of the batch)
        var remaining = current.filter { update in !sent.contains { same($0, update) } }
        // retries, unless a newer update for the same chapter was queued meanwhile
        for update in failed where !remaining.contains(where: { sameTarget($0, update) }) {
            remaining.append(update)
        }
        return remaining
    }

    func processPendingUpdates() async {
        guard !trackingState.pendingPageUpdates.isEmpty else { return }

        if let pageUpdateTask {
            await pageUpdateTask.value
            // updates queued while that batch was on the network are sent now
            await processPendingUpdates()
            return
        }

        pageUpdateTask = Task {
            var stillPending: [PageTrackUpdate] = []
            var successes = 0
            let batch = trackingState.pendingPageUpdates

            for var update in batch {
                guard let tracker = pageTrackerLookup(update.trackerId) as? PageTracker else {
                    continue // tracker no longer exists, remove the update
                }
                do {
                    try await tracker.setProgress(
                        trackId: update.trackId,
                        chapterId: update.chapterId,
                        progress: update.progress
                    )
                    if update.failCount > 0 {
                        successes += 1
                    }
                } catch {
                    LogManager.logger.error("Failed to set tracker progress (\(tracker.id)): \(error)")
                    update.failCount += 1
                    if update.failCount >= 3 {
                        LogManager.logger.warn("Removing failed page update after 3 attempts: \(update)")
                        continue // remove update after three failed attempts (initial + two retries)
                    }
                    stillPending.append(update)
                }
            }

            if successes > 0 {
                LogManager.logger.info("Processed \(successes) previously failed page tracker update\(successes > 1 ? "s" : "")")
            }

            trackingState.pendingPageUpdates = Self.remainingPageUpdates(
                current: trackingState.pendingPageUpdates,
                sent: batch,
                failed: stillPending
            )
            savePageTrackingState()
            pageUpdateTask = nil
        }
    }

    private func savePageTrackingState() {
        guard let stateKey else { return }
        let data = try? JSONEncoder().encode(trackingState)
        if let data {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    /// The pending page updates were rewritten in the settings (SUWA-12 conversion): read them again so a
    /// later save doesn't bring the old source keys back.
    func reloadPageTrackingState() {
        guard let stateKey else { return }
        trackingState = UserDefaults.standard.data(forKey: stateKey)
            .flatMap { try? JSONDecoder().decode(TrackingState.self, from: $0) } ?? .init()
    }

    /// Waits for the page updates being sent (the reader's immediate save, inside a background task).
    func waitForPendingPageUpdates() async {
        await pageUpdateTask?.value
    }

    /// Queues and sends page updates. For tests.
    func sendPageUpdates(_ updates: [PageTrackUpdate]) async {
        queuePageUpdates(updates)
        await processPendingUpdates()
    }

    var pendingPageUpdates: [PageTrackUpdate] { trackingState.pendingPageUpdates }

    private func queuePageUpdates(_ updates: [PageTrackUpdate]) {
        // merge new updates into existing failed updates, preserving the latest ones
        for update in updates {
            // remove any old update, assuming it's not as recent as the new one
            let existingUpdateIndex = trackingState.pendingPageUpdates.firstIndex(where: {
                $0.trackerId == update.trackerId && $0.trackId == update.trackId && $0.chapterId == update.chapterId
            })
            if let existingUpdateIndex {
                trackingState.pendingPageUpdates.remove(at: existingUpdateIndex)
            }
            // add new update
            trackingState.pendingPageUpdates.append(update)
        }
        savePageTrackingState()
    }
}
