//
//  MangaView+ViewModel.swift
//  Aidoku
//
//  Created by Skitty on 4/29/25.
//

import AidokuRunner
import Combine
import SwiftUI

extension MangaView {
    @MainActor
    class ViewModel: ObservableObject {
        @Published var source: AidokuRunner.Source?
        /// The installed sources are loaded: a missing source is really missing (no notice flicker before).
        @Published var sourcesLoaded: Bool

        @Published var manga: AidokuRunner.Manga
        @Published var chapters: [AidokuRunner.Chapter] = []
        @Published var otherDownloadedChapters: [AidokuRunner.Chapter] = []

        @Published var readingHistory: [String: (page: Int, date: Int)] = [:]
        @Published var downloadProgress: [String: Float] = [:] // chapterId: progress
        @Published var downloadStatus: [String: DownloadStatus] = [:] // chapterId: status

        @Published var bookmarked = false
        @Published var hasCategories = false

        @Published var nextChapter: AidokuRunner.Chapter?
        @Published var readingInProgress = false
        @Published var allChaptersLocked = false
        @Published var allChaptersRead = false
        @Published var initialDataLoaded = false

        @Published var chapterSortOption: ChapterSortOption = .sourceOrder {
            didSet {
                refilterChapters()
                rememberSort()
            }
        }
        @Published var chapterSortAscending = false {
            didSet {
                refilterChapters()
                rememberSort()
            }
        }
        /// Set while the stored order is applied (not a choice of the user). SUWA-12 G2.
        var applyingStoredSort = false
        /// This manga has an order chosen (its own), not the one inherited. SUWA-12 H5.
        private var sortChosen = false

        @Published var chapterFilters: [ChapterFilterOption] = [] {
            didSet { refilterChapters() }
        }
        @Published var chapterLangFilter: String? {
            didSet { refilterChapters() }
        }
        @Published var chapterScanlatorFilter: [String] = [] {
            didSet { refilterChapters() }
        }

        @Published var chapterTitleDisplayMode: ChapterTitleDisplayMode

        @Published var error: Error?

        /// «Descarga adelantada» after a refresh found new chapters (injectable for tests).
        var downloadAheadTrigger: @Sendable (MangaIdentifier) async -> Void = { mangaId in
            await DownloadManager.shared.ensureAheadDownloaded(mangaId: mangaId)
        }

        private var fetchedDetails = false
        private var markedOpened = false
        private var cancellables = Set<AnyCancellable>()

        init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga) {
            self.source = source
            self.sourcesLoaded = source != nil
            self.manga = manga

            let key = "Manga.chapterDisplayMode.\(manga.identifier)"
            self.chapterTitleDisplayMode = .init(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .default

            registerNotifications()

            if source == nil {
                let sourceKey = manga.sourceKey
                Task { @MainActor [weak self] in
                    await SourceManager.shared.waitForSourcesLoad()
                    guard let self else { return }
                    if self.source == nil {
                        self.source = SourceManager.shared.store.source(for: sourceKey)
                    }
                    self.sourcesLoaded = true
                }
            }
        }
    }
}

// MARK: Notifications
extension MangaView.ViewModel {
    private func registerNotifications() {
        registerLibraryNotifications()
        registerSourceNotifications()
        registerHistoryNotifications()
        registerTrackingNotifications()
        registerDownloadsNotifications()
        registerSettingsNotifications()
    }

    private func registerLibraryNotifications() {
        NotificationCenter.default.publisher(for: .updateLibrary)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.loadBookmarked()
                    await self.checkForCategories()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .updateMangaDetails)
            .sink { [weak self] output in
                Task { @MainActor in
                    guard
                        let self,
                        let manga = output.object as? AidokuRunner.Manga,
                        manga.identifier == self.manga.identifier
                            else {
                        return
                    }
                    self.manga = manga
                }
            }
            .store(in: &cancellables)

        for name in [
            Notification.Name.addToLibrary,
            Notification.Name.removeFromLibrary
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] output in
                    Task { @MainActor in
                        guard
                            let self,
                            let id = output.object as? MangaIdentifier,
                            id == self.manga.identifier
                        else {
                            return
                        }
                        await self.loadBookmarked()
                    }
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: .migratedManga)
            .sink { [weak self] output in
                Task { @MainActor in
                    guard
                        let self,
                        let migration = output.object as? (from: AidokuRunner.Manga, to: AidokuRunner.Manga),
                        migration.from.identifier == self.manga.identifier,
                        let newSource = SourceManager.shared.store.source(for: migration.to.sourceKey)
                    else {
                        return
                    }
                    self.source = newSource
                    self.manga = migration.to
                    await self.fetchData()
                }
            }
            .store(in: &cancellables)

            NotificationCenter.default.publisher(for: .updateCategories)
                .sink { [weak self] _ in
                    Task {
                        await self?.checkForCategories()
                    }
                }
                .store(in: &cancellables)
    }

    private func registerSourceNotifications() {
        for notification in [Notification.Name.sourceLoaded, Notification.Name.sourceUnloaded] {
            NotificationCenter.default.publisher(for: notification)
                .sink { [weak self] output in
                    Task { @MainActor in
                        guard
                            let self,
                            let sourceKey = output.object as? String,
                            self.manga.sourceKey == sourceKey
                        else {
                            return
                        }
                        self.source = SourceManager.shared.store.source(for: sourceKey)
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func registerHistoryNotifications() {
        NotificationCenter.default.publisher(for: .updateHistory)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.loadHistory()
                    self.chapters = self.filteredChapters()
                    self.updateReadButton()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .historyAdded)
            .sink { [weak self] output in
                Task { @MainActor in
                    guard
                        let self,
                        let chapters = output.object as? [ChapterIdentifier]
                            else {
                        return
                    }
                    let date = Int(Date().timeIntervalSince1970)
                    for chapterId in chapters where chapterId.mangaIdentifier == self.manga.identifier {
                        self.readingHistory[chapterId.chapterKey] = (page: -1, date: date)
                    }
                    self.updateReadButton()
                    self.checkForAllReadMarkOpened()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .historyRemoved)
            .sink { [weak self] output in
                guard let self else { return }
                Task { @MainActor in
                    if let chapters = output.object as? [ChapterIdentifier] {
                        for chapterId in chapters where chapterId.mangaIdentifier == self.manga.identifier {
                            self.readingHistory.removeValue(forKey: chapterId.chapterKey)
                        }
                    } else if
                        let mangaId = output.object as? MangaIdentifier,
                        mangaId == self.manga.identifier
                            {
                        self.readingHistory = [:]
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .historySet)
            .sink { [weak self] output in
                Task { @MainActor in
                    guard
                        let self,
                        let item = output.object as? (chapterId: ChapterIdentifier, page: Int),
                        item.chapterId.mangaIdentifier == self.manga.identifier,
                        self.readingHistory[item.chapterId.chapterKey]?.page != -1
                            else {
                        return
                    }
                    self.readingHistory[item.chapterId.chapterKey] = (
                        page: item.page,
                        date: Int(Date().timeIntervalSince1970)
                    )
                    self.updateReadButton()
                    self.checkForAllReadMarkOpened()
                }
            }
            .store(in: &cancellables)
    }

    private func registerTrackingNotifications() {
        NotificationCenter.default.publisher(for: .syncTrackItem)
            .sink { [weak self] output in
                guard let self, let item = output.object as? TrackItem else { return }
                Task { @MainActor in
                    await self.checkTrackerSync(item: item)
                }
            }
            .store(in: &cancellables)
    }

    private func registerDownloadsNotifications() {
        NotificationCenter.default.publisher(for: .downloadsQueued)
            .sink { [weak self] output in
                guard let self, let downloads = output.object as? [Download] else { return }
                Task { @MainActor in
                    let chapters = downloads.compactMap {
                        if $0.mangaIdentifier == self.manga.identifier {
                            $0.chapter
                        } else {
                            nil
                        }
                    }
                    for chapter in chapters {
                        self.downloadStatus[chapter.key] = .queued
                        self.downloadProgress[chapter.key] = 0
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .downloadProgressed)
            .sink { [weak self] output in
                Task { @MainActor in
                    guard
                        let self,
                        let download = output.object as? Download,
                        download.mangaIdentifier == self.manga.identifier
                    else {
                        return
                    }
                    self.downloadStatus[download.chapterIdentifier.chapterKey] = .downloading
                    self.downloadProgress[download.chapterIdentifier.chapterKey] = Float(download.progress) / Float(download.total)
                }
            }
            .store(in: &cancellables)

        for name in [
            Notification.Name.downloadFinished,
            Notification.Name.downloadFailed,
            Notification.Name.downloadRemoved,
            Notification.Name.downloadCancelled
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] output in
                    Task { @MainActor in
                        self?.removeDownload(output)
                    }
                }
                .store(in: &cancellables)
        }

        for name in [
            Notification.Name.downloadsRemoved,
            Notification.Name.downloadsCancelled
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] output in
                    Task { @MainActor in
                        self?.removeDownloads(output)
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func registerSettingsNotifications() {
        NotificationCenter.default.publisher(for: .init(AppSettings.library.resumeLastOpenedChapter.key))
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.updateReadButton()
                }
            }
            .store(in: &cancellables)
    }
}

extension MangaView.ViewModel {
    func checkForCategories() async {
        let hasCategories = await !DataRepositories.shared.categories.titles(includeFilterGroups: false).isEmpty
        if self.hasCategories != hasCategories {
            self.hasCategories = hasCategories
        }
    }

    func refreshReadButtonState() {
        updateReadButton()
    }

    func markUpdatesViewed() async {
        if !AppSettings.general.incognitoMode.get() {
            await MangaUpdateManager.shared.viewAllUpdates(of: manga)
        }
    }

    private func checkForAllReadMarkOpened() {
        guard !markedOpened else { return }
        if getNextChapter() == .allRead {
            markedOpened = true
            Task {
                await CoreDataManager.shared.setOpened(mangaId: manga.identifier)
                NotificationCenter.default.post(name: .openedManga, object: manga.identifier)
            }
        }
    }

    // fetch complete info for manga, called when view appears
    func fetchDetails() async {
        guard !fetchedDetails else { return }
        fetchedDetails = true

        let context = CoreDataManager.shared.context

        if let cachedManga = CoreDataManager.shared.getManga(mangaId: self.manga.identifier, context: context) {
            self.manga = self.manga.copy(from: cachedManga.toNewManga())
        }

        let filters = CoreDataManager.shared.getMangaChapterFilters(mangaId: manga.identifier, context: context)
        let sort = ChapterSortMemory.load(for: manga.identifier, flags: filters.flags)
        sortChosen = ChapterSortMemory.isChosen(for: manga.identifier, flags: filters.flags)
        applyingStoredSort = true
        chapterSortOption = ChapterSortOption(rawValue: sort.option) ?? .sourceOrder
        chapterSortAscending = sort.ascending
        applyingStoredSort = false
        chapterFilters = ChapterFilterOption.parseOptions(flags: filters.flags)
        chapterLangFilter = filters.language
        chapterScanlatorFilter = filters.scanlators ?? []

        await loadBookmarked()
        await adoptLocalSort(flags: filters.flags)
        await loadHistory()
        await fetchData()
    }

    // fetches manga data, from coredata if in library or from source if not
    func fetchData() async {
        let mangaId = manga.identifier
        let inLibrary = await DataRepositories.shared.library.contains(mangaId)
        if inLibrary {
            // load data from db
            let chapters = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
                CoreDataManager.shared.getChapters(
                    mangaId: mangaId,
                    context: context
                ).map {
                    $0.toNewChapter()
                }
            }

            var newManga = self.manga
            newManga.chapters = chapters
            withAnimation {
                self.manga = newManga
                self.chapters = filteredChapters()
            }
        } else if let source {
            // load new data from source
            await source.partialMangaPublisher?.sink { @Sendable newManga in
                Task { @MainActor in
                    withAnimation {
                        self.manga = self.manga.copy(from: newManga)
                        self.chapters = self.filteredChapters()
                    }
                }
            }
            do {
                let newManga = try await source.getMangaUpdate(
                    manga: manga,
                    needsDetails: true,
                    needsChapters: true
                )
                withAnimation {
                    manga = newManga
                    chapters = filteredChapters()
                }
            } catch {
                withAnimation {
                    self.manga.chapters = []
                    self.chapters = []
                    self.error = error
                }
            }
            await source.partialMangaPublisher?.removeSink()
        }
        await fetchDownloadedChapters()
        await loadDownloadStatus()
        updateReadButton()
        initialDataLoaded = true
    }

    func fetchDownloadedChapters() async {
        let downloadedChapters = await DownloadManager.shared.getDownloadedChapters(for: manga.identifier)
            .filter { chapter in
                !(manga.chapters ?? chapters).contains(where: { $0.key.directoryName == chapter.chapterId.directoryName })
            }
            .map { $0.toChapter() }
            .sorted { (lhs: AidokuRunner.Chapter, rhs: AidokuRunner.Chapter) in
                // Primary sort: by chapter number if both have it
                if let lhsChapter = lhs.chapterNumber, let rhsChapter = rhs.chapterNumber {
                    if lhsChapter != rhsChapter {
                        return lhsChapter > rhsChapter
                    }
                    // If chapter numbers are equal, sort by volume number
                    if let lhsVolume = lhs.volumeNumber, let rhsVolume = rhs.volumeNumber {
                        return lhsVolume > rhsVolume
                    }
                }

                // Secondary sort: by volume number if only one has chapter number
                if let lhsVolume = lhs.volumeNumber, let rhsVolume = rhs.volumeNumber {
                    return lhsVolume > rhsVolume
                }

                // Final fallback: alphabetical comparison of display titles
                let lhsTitle = lhs.title?.lowercased() ?? ""
                let rhsTitle = rhs.title?.lowercased() ?? ""
                return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedDescending
            }
        withAnimation {
            otherDownloadedChapters = downloadedChapters
        }
    }

    func syncTrackerProgress() async {
        // sync progress from page trackers
        await TrackerManager.shared.syncPageTrackerHistory(
            manga: manga,
            chapters: chapters
        )

        // sync progress from regular trackers if auto sync enabled
        if AppSettings.tracking.autoSyncFromTracker.get() {
            let trackItems = await DataRepositories.shared.tracks.items(of: manga.identifier)
            for trackItem in trackItems {
                guard let tracker = TrackerManager.getTracker(id: trackItem.trackerId) else { continue }
                await TrackerManager.shared.syncProgressFromTracker(
                    tracker: tracker,
                    trackItem: trackItem,
                    manga: manga,
                    chapters: chapters
                )
            }
        }
    }

    // refresh manga and chapter data from source, updating db
    func refresh() async {
        guard Reachability.getConnectionType() != .none, let source else {
            return
        }

        let mangaId = manga.identifier

        let inLibrary = await DataRepositories.shared.library.contains(mangaId)

        do {
            let oldManga = self.manga
            var newManga = try await source.getMangaUpdate(
                manga: oldManga,
                needsDetails: true,
                needsChapters: true
            )

            // update manga in db
            if inLibrary {
                let (resultManga, foundNewChapters): (AidokuRunner.Manga?, Bool) =
                    await CoreDataManager.shared.container.performBackgroundTask { [
                        newManga,
                        chapterLangFilter,
                        chapterScanlatorFilter
                    ] context in
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
                        mangaObject.load(from: newManga)

                        var foundNewChapters = false
                        if let chapters = newManga.chapters {
                            let newChapters = CoreDataManager.shared.setChapters(
                                chapters,
                                mangaId: mangaId,
                                context: context
                            )
                            if !newChapters.isEmpty {
                                foundNewChapters = true
                                // add manga updates
                                for chapter in newChapters
                                where
                                    chapterLangFilter != nil ? chapter.lang == chapterLangFilter : true
                                    && !chapterScanlatorFilter.isEmpty ? chapterScanlatorFilter.contains(chapter.scanlator ?? "") : true
                                {
                                    CoreDataManager.shared.createMangaUpdate(
                                        mangaId: mangaId,
                                        chapterObject: chapter,
                                        context: context
                                    )
                                }
                                libraryObject.lastChapter = chapters.compactMap { $0.dateUploaded }.max()
                                libraryObject.lastUpdatedChapters = Date.now
                            }
                        }

                        let now = Date.now
                        libraryObject.lastUpdated = now

                        if !AppSettings.general.incognitoMode.get() {
                            libraryObject.lastOpened = now.addingTimeInterval(1) // ensure item isn't re-pinned, since it's already open
                        }

                        try? context.save()

                        return (mangaObject.toNewManga(), foundNewChapters)
                    }

                if newManga.chapters != nil {
                    await markUpdatesViewed()
                }

                if var resultManga {
                    resultManga.chapters = newManga.chapters
                    newManga = resultManga
                }

                NotificationCenter.default.post(name: .updateManga, object: newManga.identifier)

                if foundNewChapters {
                    // «descarga adelantada»: new chapters may fall in the window (on its own; Wi-Fi rule applies)
                    let trigger = downloadAheadTrigger
                    Task {
                        await trigger(mangaId)
                    }
                }
            }

            await loadHistory()

            withAnimation {
                manga = newManga
                chapters = filteredChapters()
            }

            // ensure downloaded chapters are in the correct section if they were added/removed from the main list
            await fetchDownloadedChapters()

            // sync history with tracker
            await syncTrackerProgress()
        } catch {
            withAnimation {
                self.manga.chapters = []
                self.chapters = []
                self.error = error
            }
        }

        updateReadButton()
    }

    private func loadDownloadStatus() async {
        for chapter in (manga.chapters ?? chapters) + otherDownloadedChapters {
            downloadStatus[chapter.key] = DownloadManager.shared.getDownloadStatus(
                for: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
            )
        }
    }

    private func loadBookmarked() async {
        let mangaId = manga.identifier
        let inLibrary = await DataRepositories.shared.library.contains(mangaId)
        if bookmarked != inLibrary {
            bookmarked = inLibrary
        }
    }

    private func loadHistory() async {
        readingHistory = await CoreDataManager.shared.getReadingHistory(mangaId: manga.identifier)
    }

    private func checkTrackerSync(item: TrackItem) async {
        guard let tracker = TrackerManager.getTracker(id: item.trackerId) else { return }

        if tracker is PageTracker {
            await TrackerManager.shared.syncPageTrackerHistory(
                tracker: tracker,
                manga: self.manga,
                chapters: self.chapters
            )
            return
        }

        let chaptersToMark = await TrackerManager.shared.getChaptersToSyncProgressFromTracker(
            tracker: tracker,
            trackItem: item,
            manga: self.manga,
            chapters: self.chapters
        ).filter {
            readingHistory[$0.key]?.page != -1 // filter out chapters already marked read
        }

        if !chaptersToMark.isEmpty {
            let alert = UIAlertController(
                title: NSLocalizedString("SYNC_WITH_TRACKER"),
                message: chaptersToMark.count == 1
                    ? NSLocalizedString("SYNC_WITH_TRACKER_INFO_1")
                    : String(format: NSLocalizedString("SYNC_WITH_TRACKER_INFO_%i"), chaptersToMark.count),
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel) { _ in })

            alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default) { [weak self] _ in
                guard let self else { return }
                Task {
                    await HistoryManager.shared.addHistory(
                        mangaId: self.manga.identifier,
                        chapters: chaptersToMark,
                        skipTracker: tracker,
                        reason: "ficha: sincronizar con \(tracker.id)"
                    )
                }
            })

            UIApplication.shared.appDelegate?.visibleViewController?.present(alert, animated: true)
        }
    }
}

extension MangaView.ViewModel {
    // every chapter row shown in the list, across both sections
    var listedChapters: [AidokuRunner.Chapter] {
        chapters + otherDownloadedChapters
    }

    // resolve selected chapter keys, which can come from either the chapter list
    // or the separate downloaded chapters section
    func chapters(forKeys keys: Set<String>) -> [AidokuRunner.Chapter] {
        listedChapters.filter { keys.contains($0.key) }
    }

    // mark given chapters as read in coredata
    func markRead(chapters: [AidokuRunner.Chapter]) async {
        // only mark chapters that are readable as read
        let chapters = chapters.filter { !$0.locked || downloadStatus[$0.key] == .finished }

        await HistoryManager.shared.addHistory(
            mangaId: manga.identifier,
            chapters: chapters,
            reason: "ficha: marcar como leído"
        )
        let date = Int(Date().timeIntervalSince1970)
        for chapter in chapters {
            readingHistory[chapter.key] = (page: -1, date: date)
        }
        updateReadButton()
    }

    // remove coredata history for given chapters
    func markUnread(chapters: [AidokuRunner.Chapter]) async {
        await HistoryManager.shared.removeHistory(
            chapterIds: chapters.map {
                .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
            }
        )
        for chapter in chapters {
            readingHistory[chapter.key] = nil
        }
        updateReadButton()
    }

    /// The chapters before `chapter` for «Marcar anteriores» (SUWA-12 G1).
    func previousChapters(before chapter: AidokuRunner.Chapter) -> [AidokuRunner.Chapter] {
        ChapterOrder.previous(of: chapter, inSourceOrder: manga.chapters ?? [])
    }

    /// The order chosen is this manga's and the default for the rest (SUWA-12 G2).
    private func rememberSort() {
        guard !applyingStoredSort else { return }
        sortChosen = true
        // in the library it goes to the flags (refilterChapters saves them), out of it to the device
        ChapterSortMemory.record(
            .init(option: chapterSortOption.rawValue, ascending: chapterSortAscending),
            for: manga.identifier,
            inLibrary: bookmarked
        )
    }

    /// A manga of the library with an order of this device (chosen before it was added, or with the build
    /// of 15-nov): the order goes to its flags and the device's one goes away. SUWA-12 H5.
    private func adoptLocalSort(flags: Int) async {
        guard bookmarked, ChapterSortMemory.local(for: manga.identifier) != nil else { return }
        if ChapterSortMemory.chosen(inFlags: flags) == nil {
            await saveFilters() // the order shown, the device's
        }
        ChapterSortMemory.forgetLocal(manga.identifier)
    }

    private func refilterChapters() {
        withAnimation {
            chapters = filteredChapters()
        }
        updateReadButton()
        if bookmarked {
            Task {
                await saveFilters()
            }
        }
    }

    private func removeDownload(_ notification: Notification) {
        var chapter: ChapterIdentifier?
        if let identifier = notification.object as? ChapterIdentifier {
            chapter = identifier
        } else if let download = notification.object as? Download {
            chapter = download.chapterIdentifier
        }
        if let chapter {
            downloadProgress.removeValue(forKey: chapter.chapterKey)
            downloadStatus[chapter.chapterKey] = DownloadManager.shared.getDownloadStatus(for: chapter)
            if let chapterIndex = otherDownloadedChapters.firstIndex(where: { $0.key == chapter.chapterKey }) {
                withAnimation {
                    _ = otherDownloadedChapters.remove(at: chapterIndex)
                }
            }
        }
    }

    private func removeDownloads(_ notification: Notification) {
        if let chapters = notification.object as? [ChapterIdentifier] {
            for chapter in chapters {
                downloadProgress.removeValue(forKey: chapter.chapterKey)
                downloadStatus[chapter.chapterKey] = DownloadStatus.none
            }
        } else if
            let manga = notification.object as? MangaIdentifier,
            manga == self.manga.identifier
        { // all chapters
            downloadProgress = [:]
            downloadStatus = [:]
        }
    }

    private func sortedChapters() -> [AidokuRunner.Chapter] {
        guard let chapters = manga.chapters, !chapters.isEmpty else {
            return []
        }
        return switch chapterSortOption {
            case .sourceOrder:
                chapterSortAscending ? chapters.reversed() : chapters
            case .chapter:
                if chapterSortAscending {
                    chapters.sorted(by: { $0.chapterNumber ?? -1 < $1.chapterNumber ?? -1 })
                } else {
                    chapters.sorted(by: { $0.chapterNumber ?? -1 > $1.chapterNumber ?? -1 })
                }
            case .uploadDate:
                if chapterSortAscending {
                    chapters.sorted(by: { $0.dateUploaded ?? .distantPast < $1.dateUploaded ?? .distantPast })
                } else {
                    chapters.sorted(by: { $0.dateUploaded ?? .distantPast > $1.dateUploaded ?? .distantPast })
                }
        }
    }

    private func filteredChapters() -> [AidokuRunner.Chapter] {
        var chapters = sortedChapters()

        // filter by language and scanlators
        if chapterLangFilter != nil || !chapterScanlatorFilter.isEmpty {
            chapters = chapters.filter { chapter in
                let cond1 = if let chapterLangFilter {
                    chapter.language == chapterLangFilter
                } else {
                    true
                }
                let cond2 = if !chapterScanlatorFilter.isEmpty  {
                    if let chapterScanlators = chapter.scanlators, !chapterScanlators.isEmpty {
                        chapterScanlatorFilter.contains(where: chapterScanlators.contains)
                    } else {
                        chapterScanlatorFilter.contains("")
                    }
                } else {
                    true
                }
                return cond1 && cond2
            }
        }

        for filter in chapterFilters {
            switch filter.type {
                case .downloaded:
                    chapters = chapters.filter {
                        let downloaded = !DownloadManager.shared.isChapterDownloaded(
                            chapter: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
                        )
                        return filter.exclude ? downloaded : !downloaded
                    }
                case .unread:
                    chapters = chapters.filter {
                        let isCompleted = self.readingHistory[$0.id]?.0 == -1
                        return filter.exclude ? isCompleted : !isCompleted
                    }
                case .locked:
                    chapters = chapters.filter {
                        filter.exclude ? !$0.locked : $0.locked
                    }
            }
        }

        return chapters
    }

    enum ChapterResult: Equatable {
        case none
        case allRead
        case allLocked
        case chapter(AidokuRunner.Chapter)
    }

    private func getNextChapter() -> ChapterResult {
        guard !chapters.isEmpty else { return .none }

        let chapter = MangaManager.shared.getNextChapter(
            manga: manga,
            chapters: chapters,
            readingHistory: readingHistory,
            sortAscending: chapterSortAscending
        )

        if let chapter {
            return .chapter(chapter)
        }
        if !chapters.contains(where: { !$0.locked }) {
            return .allLocked
        }
        return .allRead
    }

    private func updateReadButton() {
        let nextChapter = getNextChapter()
        switch nextChapter {
            case .none:
                self.nextChapter = nil
                readingInProgress = false
                allChaptersRead = false
                allChaptersLocked = false
            case .allRead:
                allChaptersRead = true
                allChaptersLocked = false
            case .allLocked:
                allChaptersLocked = true
            case .chapter(let nextChapter):
                allChaptersRead = false
                allChaptersLocked = false
                readingInProgress = readingHistory[nextChapter.id]?.date ?? 0 > 0
                self.nextChapter = nextChapter
        }
    }

    private func generateChapterFlags() -> Int {
        var flags: Int = 0
        // only an order chosen goes to the library flags (an inherited one would pass for chosen on the other device)
        if sortChosen {
            flags = ChapterSortMemory.flags(.init(option: chapterSortOption.rawValue, ascending: chapterSortAscending), into: 0)
        }
        for filter in chapterFilters {
            switch filter.type {
                case .downloaded:
                    flags |= ChapterFlagMask.downloadFilterEnabled
                    if filter.exclude {
                        flags |= ChapterFlagMask.downloadFilterExcluded
                    }
                case .unread:
                    flags |= ChapterFlagMask.unreadFilterEnabled
                    if filter.exclude {
                        flags |= ChapterFlagMask.unreadFilterExcluded
                    }
                case .locked:
                    flags |= ChapterFlagMask.lockedFilterEnabled
                    if filter.exclude {
                        flags |= ChapterFlagMask.lockedFilterExcluded
                    }
            }
        }
        return flags
    }

    private func saveFilters() async {
        let manga = manga.toOld()
        manga.chapterFlags = generateChapterFlags()
        manga.langFilter = chapterLangFilter
        manga.scanlatorFilter = chapterScanlatorFilter
        await CoreDataManager.shared.updateMangaDetails(manga: manga)
        NotificationCenter.default.post(name: .filteredChapters, object: manga.identifier)
    }
}
