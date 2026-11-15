//
//  DownloadQueue.swift
//  Aidoku
//
//  Created by Skitty on 5/13/22.
//

import AidokuRunner
@preconcurrency import BackgroundTasks
import Foundation

// stores queued and active downloads
// creates a downloadtask for every source
// only one chapter per source is downloaded at a time
actor DownloadQueue {
    /// When adding downloads: start the queue, leave it as it is, or start it unless the user paused it.
    enum AutoStart: Sendable {
        case always
        case never
        case unlessUserPaused
    }

    private let cache: DownloadCache
    /// UserDefaults key for the saved queue (nil: not saved, for tests).
    private let stateKey: String?
    private var onCompletion: (() -> Void)?

    private(set) var queue: [String: [Download]] = [:] { // all queued downloads stored under source id
        didSet {
            if hasNoDownloads {
                resumeEmptyWaiters(true)
            }
        }
    }
    private var emptyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var tasks: [String: DownloadTask] = [:] // tasks for each source
    private var progressBlocks: [ChapterIdentifier: (Int, Int) -> Void] = [:]

    private var paused = false
#if DEBUG
    /// Tasks created and not finished, per source, and the most seen at once (one is the rule). For tests.
    private var aliveTasks: [String: Int] = [:]
    private(set) var maxAliveTasksPerSource = 0
#endif
    /// How the tasks find a source (injectable for tests).
    private let sourceLookup: DownloadTask.SourceLookup
    /// Paused from the download queue UI (not by the Wi-Fi rule or the background task expiring).
    private var userPaused = false
    private var registeredTask = false
    private var totalDownloads: Int = 0
    private var completedDownloads: Int = 0
    private var bgTask: ProgressReporting?
    private var sendCancelNotification = true

    private static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".download"

    init(
        cache: DownloadCache,
        onCompletion: (() -> Void)? = nil,
        stateKey: String? = "Data.downloadQueueState",
        sourceLookup: @escaping DownloadTask.SourceLookup = DownloadTask.defaultSourceLookup
    ) {
        self.cache = cache
        self.onCompletion = onCompletion
        self.stateKey = stateKey
        self.sourceLookup = sourceLookup
    }

    /// The task of a source, created if needed. Stored before any suspension point, so a reentrant call
    /// can't create a second one.
    @discardableResult
    func makeTaskIfNeeded(sourceKey: String) -> DownloadTask {
        if let task = tasks[sourceKey] {
            return task
        }
        let task = DownloadTask(
            id: sourceKey, cache: cache, downloads: queue[sourceKey] ?? [], delegate: self, sourceLookup: sourceLookup
        )
        tasks[sourceKey] = task
#if DEBUG
        aliveTasks[sourceKey, default: 0] += 1
        maxAliveTasksPerSource = max(maxAliveTasksPerSource, aliveTasks[sourceKey] ?? 0)
#endif
        return task
    }

    /// Chapter keys the source's task holds (nil without a task). For tests.
    func taskChapterKeys(sourceKey: String) async -> [String]? {
        guard let task = tasks[sourceKey] else { return nil }
        return await task.downloads.map(\.chapterIdentifier.chapterKey)
    }

    func isPaused() -> Bool {
        paused
    }

    func setOnCompletion(_ onCompletion: (() -> Void)?) {
        self.onCompletion = onCompletion
    }

    func start() async {
        paused = false
        userPaused = false

        guard !queue.isEmpty else { return }

#if !targetEnvironment(simulator)
        if
            bgTask == nil,
            #available(iOS 26.0, *),
            AppSettings.downloads.background.get(),
            !ProcessInfo.processInfo.isMacCatalystApp
        {
            await register()

            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.taskIdentifier,
                title: NSLocalizedString("DOWNLOADING"),
                subtitle: NSLocalizedString("PROCESSING_QUEUE")
            )
            do {
                try await BGTaskScheduler.shared.submit(request: request)
                return
            } catch {
                LogManager.logger.error("Failed to start background downloading: \(error)")
            }
        }
#endif

        await initAndResumeTasks()
    }

    private func initAndResumeTasks() async {
        for sourceKey in queue.keys {
            await makeTaskIfNeeded(sourceKey: sourceKey).resume()
        }
    }

    /// - unlessUserPaused: do nothing if the user paused the queue (automatic resume, e.g. Wi-Fi is back).
    ///   Returns whether it resumed. Checked inside the queue, so a pause can't slip in between.
    @discardableResult
    func resume(unlessUserPaused: Bool) async -> Bool {
        if unlessUserPaused && userPaused {
            return false
        }
        await resume()
        return true
    }

    func resume() async {
        paused = false
        userPaused = false

        if #available(iOS 26.0, *), AppSettings.downloads.background.get() {
            if bgTask == nil {
                await start()
            }
        }

        // downloads added while paused (without autoStart) for a source with no task yet
        for sourceKey in queue.keys {
            makeTaskIfNeeded(sourceKey: sourceKey)
        }

        await withTaskGroup(of: Void.self) { group in
            for task in tasks.values {
                group.addTask { await task.resume() }
            }
        }
    }

    func pause(byUser: Bool = false) async {
        paused = true
        if byUser {
            userPaused = true
        }

        if #available(iOS 26.0, *) {
            if let task = bgTask as? BGContinuedProcessingTask {
                task.updateTitle(
                    NSLocalizedString("DOWNLOADING"),
                    subtitle: NSLocalizedString("PAUSED")
                )
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for task in tasks.values {
                group.addTask { await task.pause() }
            }
        }
    }

    @discardableResult
    func add(chapters: [AidokuRunner.Chapter], manga: AidokuRunner.Manga, autoStart: Bool = true) async -> [Download] {
        await add(chapters: chapters, manga: manga, start: autoStart ? .always : .never)
    }

    @discardableResult
    func add(chapters: [AidokuRunner.Chapter], manga: AidokuRunner.Manga, start autoStart: AutoStart) async -> [Download] {
        var downloads: [Download] = []
        for chapter in chapters {
            let identifier = ChapterIdentifier(
                sourceKey: manga.sourceKey,
                mangaKey: manga.key,
                chapterKey: chapter.key
            )
            guard !(await cache.isChapterDownloaded(identifier: identifier)) else {
                continue
            }

            // create tmp directory so we know it's queued
            if !DownloadManager.directory.exists {
                DownloadManager.prepareDirectory() // removed meanwhile: created again out of the backup
            }
            let tmpDirectory = cache.tmpDirectory(for: identifier)
            tmpDirectory.removeItem() // remove in case it exists from a previous failed download
            tmpDirectory.createDirectory()

            let download = Download.from(manga: manga, chapter: chapter)
            downloads.append(download)
            if queue[manga.sourceKey] == nil {
                queue[manga.sourceKey] = [download]
            } else {
                queue[manga.sourceKey]?.append(download)
            }
            // also when the source had nothing queued: its task may still exist (everything cancelled)
            await tasks[manga.sourceKey]?.add(download: download)
        }
        totalDownloads += downloads.count
        bgTask?.progress.totalUnitCount = Int64(totalDownloads)
        // checked right before starting, inside the queue: no pause can slip in between
        if autoStart == .always || (autoStart == .unlessUserPaused && !userPaused) {
            await start()
        }
        saveQueueState()
        return downloads
    }

    func cancelDownload(for chapter: ChapterIdentifier) async {
        if let task = tasks[chapter.sourceKey] {
            await task.cancel(chapter: chapter)
        } else {
            // no longer in queue but the tmp download directory still exists, so we should remove it
            cache.tmpDirectory(for: chapter).removeItem()
        }
        saveQueueState()
    }

    func cancelDownloads(for chapters: [ChapterIdentifier]) async {
        // disable individual download cancelled notifications
        sendCancelNotification = false
        defer { sendCancelNotification = true }
        for chapter in chapters {
            if let task = tasks[chapter.sourceKey] {
                await task.cancel(chapter: chapter)
            } else {
                cache.tmpDirectory(for: chapter).removeItem()
            }
            if let queueItem = queue[chapter.sourceKey]?.firstIndex(where: {
                $0.chapterIdentifier == chapter
            }) {
                queue[chapter.sourceKey]?.remove(at: queueItem)
            }
        }
        NotificationCenter.default.post(name: .downloadsCancelled, object: chapters)
        saveQueueState()
    }

    func cancelDownloads(for manga: MangaIdentifier) async {
        if let task = tasks[manga.sourceKey] {
            await task.cancel(manga: manga)
        } else {
            cache.directory(for: manga)
                .contentsIncludingHidden
                .filter {
                    $0.lastPathComponent.hasPrefix(DownloadCache.tmpDirectoryPrefix)
                        && !cache.hasFailureMarker(inTmpDirectory: $0)
                }
                .forEach { $0.removeItem() }
        }
        saveQueueState()
    }

    func cancelAll() async {
        sendCancelNotification = false
        defer { sendCancelNotification = true }
        for task in tasks {
            await task.value.cancel()
        }
        queue = [:]
        NotificationCenter.default.post(name: .downloadsCancelled, object: nil)
        saveQueueState()
    }

    // register callback for download progress change
    func onProgress(for chapter: ChapterIdentifier, block: @escaping (Int, Int) -> Void) {
        progressBlocks[chapter] = block
    }

    func removeProgressBlock(for chapter: ChapterIdentifier) {
        progressBlocks.removeValue(forKey: chapter)
    }

    func saveQueueState() {
        guard let stateKey else { return }
        let queueData = try? JSONEncoder().encode(queue)
        UserDefaults.standard.set(queueData, forKey: stateKey)
    }

    func loadQueueState() async {
        guard
            let stateKey,
            let queueData = UserDefaults.standard.data(forKey: stateKey),
            let queueState = try? JSONDecoder().decode([String: [Download]].self, from: queueData)
        else {
            return
        }
        queue = queueState
        if !queue.isEmpty {
            await start()
        }
    }

    func isPausedByUser() -> Bool {
        userPaused
    }

    /// Waits until the queue is empty (true) or `stopWaitingForEmpty` is called (false), without
    /// spinning.
    func waitUntilEmpty() async -> Bool {
        if hasNoDownloads { return true }
        return await withCheckedContinuation { emptyWaiters.append($0) }
    }

    /// Ends the waits (the background task expired).
    func stopWaitingForEmpty() {
        resumeEmptyWaiters(false)
    }

    /// No download left (a source whose downloads were cancelled without a task keeps an empty list).
    private var hasNoDownloads: Bool {
        queue.values.allSatisfy(\.isEmpty)
    }

    private func resumeEmptyWaiters(_ emptied: Bool) {
        let waiters = emptyWaiters
        emptyWaiters = []
        waiters.forEach { $0.resume(returning: emptied) }
    }

    func hasQueuedDownloads() -> Bool {
        !queue.isEmpty
    }

    func isRunning() async -> Bool {
        for task in tasks where await task.value.running {
            return true
        }
        return false
    }
}

extension DownloadQueue {
    private func setBackgroundTask(_ task: ProgressReporting?) {
        bgTask = task
        totalDownloads = queue.values.reduce(0) { $0 + $1.count }
        completedDownloads = 0
        bgTask?.progress.totalUnitCount = Int64(totalDownloads)
    }

#if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private func register() async {
        guard !registeredTask else { return }
        registeredTask = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { @Sendable [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else { return }

            task.expirationHandler = {
                Task {
                    await self.stopWaitingForEmpty()
                    await DownloadManager.shared.pauseDownloads(byUser: false) // system pause: automatic downloads may start it again
                    await self.setBackgroundTask(nil)
                }
                task.setTaskCompleted(success: false)
            }

            Task { @Sendable in
                await self.setBackgroundTask(task)
                await self.initAndResumeTasks()

                // wait until downloads complete (woken when the queue empties, not polled), or until expiry
                guard await self.waitUntilEmpty() else { return } // expired: already completed

                await self.setBackgroundTask(nil)

                task.setTaskCompleted(success: true)
            }
        }
    }
#endif
}

// MARK: - Task Delegate
extension DownloadQueue: DownloadTaskDelegate {
    func taskCancelled(task: DownloadTask) async {
        await taskFinished(task: task)
    }

    func taskPaused(task _: DownloadTask) async {}

    func taskFinished(task: DownloadTask) async {
#if DEBUG
        aliveTasks[task.id, default: 1] -= 1
#endif
        tasks.removeValue(forKey: task.id)
        queue.removeValue(forKey: task.id)
        saveQueueState()
    }

    func downloadFinished(download: Download) async {
        await downloadCancelled(download: download)
        progressBlocks.removeValue(forKey: download.chapterIdentifier)
        onCompletion?()
        NotificationCenter.default.post(name: .downloadFinished, object: download)
    }

    func downloadFailed(download: Download) async {
        await downloadCancelled(download: download)
        progressBlocks.removeValue(forKey: download.chapterIdentifier)
        onCompletion?()
        NotificationCenter.default.post(name: .downloadFailed, object: download)
    }

    func downloadCancelled(download: Download) async {
        var sourceDownloads = queue[download.chapterIdentifier.sourceKey] ?? []
        sourceDownloads.removeAll { $0 == download }
        if sourceDownloads.isEmpty {
            queue.removeValue(forKey: download.chapterIdentifier.sourceKey)
        } else {
            queue[download.chapterIdentifier.sourceKey] = sourceDownloads
        }
        saveQueueState()
        progressBlocks.removeValue(forKey: download.chapterIdentifier)
        if sendCancelNotification {
            NotificationCenter.default.post(name: .downloadCancelled, object: download)
        }

        completedDownloads += 1
        bgTask?.progress.completedUnitCount = Int64(completedDownloads)

        if #available(iOS 26.0, *) {
            if !paused, let task = bgTask as? BGContinuedProcessingTask {
                task.updateTitle(
                    NSLocalizedString("DOWNLOADING"),
                    subtitle: String(format: NSLocalizedString("%i_OF_%i"), completedDownloads, totalDownloads)
                )
            }
        }
    }

    func downloadProgressChanged(download: Download) async {
        if let index = queue[download.chapterIdentifier.sourceKey]?.firstIndex(where: { $0 == download }) {
            queue[download.chapterIdentifier.sourceKey]?[index] = download
        }
        if let block = progressBlocks[download.chapterIdentifier] {
            block(download.progress, download.total)
        }
        NotificationCenter.default.post(name: .downloadProgressed, object: download)
    }
}
