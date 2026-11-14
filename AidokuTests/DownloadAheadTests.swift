//
//  DownloadAheadTests.swift
//  AidokuTests
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct DownloadAheadTests {
    /// Chapters 1...count in reading order (oldest first), keys "c1", "c2", …
    private func chapters(_ count: Int, locked: Set<Int> = []) -> [AidokuRunner.Chapter] {
        (1...count).map { .init(key: "c\($0)", chapterNumber: Float($0), locked: locked.contains($0)) }
    }

    private func read(_ numbers: [Int], inProgress: [Int: Int] = [:]) -> [String: (page: Int, date: Int)] {
        var history: [String: (page: Int, date: Int)] = [:]
        for number in numbers {
            history["c\(number)"] = (page: -1, date: number)
        }
        for (number, page) in inProgress {
            history["c\(number)"] = (page: page, date: number)
        }
        return history
    }

    private func plan(
        _ chapters: [AidokuRunner.Chapter],
        read history: [String: (page: Int, date: Int)] = [:],
        downloaded: Set<String> = [],
        queued: Set<String> = [],
        target: Int,
        language: String? = nil,
        scanlators: [String] = []
    ) -> [String] {
        DownloadAheadPlanner.chaptersToQueue(
            chapters: chapters,
            readingHistory: history,
            downloaded: downloaded,
            queued: queued,
            target: target,
            language: language,
            scanlators: scanlators
        ).map(\.key)
    }

    // MARK: Planner

    @Test func nothingReadStartsAtTheFirstChapter() {
        #expect(plan(chapters(10), target: 3) == ["c1", "c2", "c3"])
    }

    @Test func startsAfterTheLastReadChapter() {
        // c3 was skipped without reading it: it doesn't count, the window starts after c4
        #expect(plan(chapters(10), read: read([1, 2, 4]), target: 3) == ["c5", "c6", "c7"])
        // a chapter in progress after the last read one is still the next one
        #expect(plan(chapters(10), read: read([1, 2], inProgress: [3: 5]), target: 2) == ["c3", "c4"])
    }

    @Test func lockedChaptersAreSkipped() {
        #expect(plan(chapters(10, locked: [5, 6]), read: read([4]), target: 3) == ["c7", "c8", "c9"])
    }

    @Test func downloadedAndQueuedChaptersCountButAreNotQueuedAgain() {
        #expect(plan(chapters(10), read: read([4]), downloaded: ["c5"], target: 3) == ["c6", "c7"])
        #expect(plan(chapters(10), read: read([4]), queued: ["c6"], target: 3) == ["c5", "c7"])
        #expect(plan(chapters(10), read: read([4]), downloaded: ["c5", "c7"], queued: ["c6"], target: 3).isEmpty)
        // downloads beyond the window don't move it
        #expect(plan(chapters(10), read: read([4]), downloaded: ["c9"], target: 2) == ["c5", "c6"])
    }

    @Test func zeroTargetQueuesNothing() {
        #expect(plan(chapters(10), target: 0).isEmpty)
        #expect(plan(chapters(10), read: read([2]), target: -1).isEmpty)
    }

    @Test func targetLargerThanWhatIsLeft() {
        #expect(plan(chapters(6), read: read([3]), target: 10) == ["c4", "c5", "c6"])
        #expect(plan(chapters(6), read: read([6]), target: 3).isEmpty)
        #expect(plan([], target: 3).isEmpty)
    }

    @Test func windowMovesAfterReadingOne() {
        let all = chapters(10)
        let first = plan(all, read: read([4]), target: 3)
        #expect(first == ["c5", "c6", "c7"])
        // c5..c7 downloaded, c5 read (and maybe deleted after reading): only c8 is new
        #expect(plan(all, read: read([4, 5]), downloaded: ["c6", "c7"], target: 3) == ["c8"])
        #expect(plan(all, read: read([4, 5]), downloaded: ["c5", "c6", "c7"], target: 3) == ["c8"])
    }

    @Test func chapterFiltersAreApplied() {
        let all: [AidokuRunner.Chapter] = [
            .init(key: "1-en", chapterNumber: 1, scanlators: ["A"], language: "en"),
            .init(key: "1-es-a", chapterNumber: 1, scanlators: ["A"], language: "es"),
            .init(key: "1-es-b", chapterNumber: 1, scanlators: ["B"], language: "es"),
            .init(key: "2-en", chapterNumber: 2, scanlators: ["A"], language: "en"),
            .init(key: "2-es-a", chapterNumber: 2, scanlators: ["A"], language: "es"),
            .init(key: "2-es-b", chapterNumber: 2, scanlators: ["B"], language: "es"),
            .init(key: "3-es-b", chapterNumber: 3, scanlators: ["B"], language: "es")
        ]
        #expect(plan(all, target: 2, language: "es") == ["1-es-a", "1-es-b"])
        #expect(plan(all, target: 2, language: "es", scanlators: ["B"]) == ["1-es-b", "2-es-b"])
        // read in Spanish/B: English chapters don't hold the window back
        #expect(plan(all, read: ["1-es-b": (page: -1, date: 1)], target: 2, language: "es", scanlators: ["B"]) == ["2-es-b", "3-es-b"])
        // without filters, the list as it is
        #expect(plan(all, target: 3) == ["1-en", "1-es-a", "1-es-b"])
    }

    @Test func downloadStatusMapping() {
        #expect(DownloadAheadPlanner.state(for: .finished) == .downloaded)
        #expect(DownloadAheadPlanner.state(for: .queued) == .queued)
        #expect(DownloadAheadPlanner.state(for: .downloading) == .queued)
        #expect(DownloadAheadPlanner.state(for: .paused) == .queued)
        // a failed download is out of the queue (only its tmp folder is left): missing, queue it again
        #expect(DownloadAheadPlanner.state(for: .failed) == .missing)
        #expect(DownloadAheadPlanner.state(for: .cancelled) == .missing)
        #expect(DownloadAheadPlanner.state(for: .none) == .missing)
    }

    // MARK: Setting

    @Test func settingIsStoredPerManga() {
        let manga = MangaIdentifier(sourceKey: "downloadaheadtest", mangaKey: "42")
        let other = MangaIdentifier(sourceKey: "downloadaheadtest", mangaKey: "43")
        defer {
            DownloadAheadSetting.set(0, for: manga)
            DownloadAheadSetting.set(0, for: other)
        }
        #expect(DownloadAheadSetting.key(for: manga) == "DownloadAhead.downloadaheadtest.42")
        #expect(DownloadAheadSetting.options == [0, 1, 2, 3, 5, 10])
        #expect(DownloadAheadSetting.get(for: manga) == 0)
        DownloadAheadSetting.set(3, for: manga)
        #expect(DownloadAheadSetting.get(for: manga) == 3)
        #expect(DownloadAheadSetting.get(for: other) == 0)
        #expect(UserDefaults.standard.integer(forKey: "DownloadAhead.downloadaheadtest.42") == 3)
        DownloadAheadSetting.set(0, for: manga)
        #expect(DownloadAheadSetting.get(for: manga) == 0)
        #expect(UserDefaults.standard.object(forKey: "DownloadAhead.downloadaheadtest.42") == nil)
    }

    @Test func settingFollowsMigration() {
        let old = MangaIdentifier(sourceKey: "downloadaheadtest", mangaKey: "50")
        let new = MangaIdentifier(sourceKey: "downloadaheadtest2", mangaKey: "51")
        defer {
            DownloadAheadSetting.set(0, for: old)
            DownloadAheadSetting.set(0, for: new)
        }
        DownloadAheadSetting.set(5, for: old)
        DownloadAheadSetting.migrate(from: old, to: new, copy: true)
        #expect(DownloadAheadSetting.get(for: new) == 5)
        #expect(DownloadAheadSetting.get(for: old) == 5)
        DownloadAheadSetting.set(0, for: new)
        DownloadAheadSetting.migrate(from: old, to: new, copy: false)
        #expect(DownloadAheadSetting.get(for: new) == 5)
        #expect(DownloadAheadSetting.get(for: old) == 0)
        // same manga: kept
        DownloadAheadSetting.migrate(from: new, to: new, copy: false)
        #expect(DownloadAheadSetting.get(for: new) == 5)
    }

    // MARK: ensureAheadDownloaded

    /// A library manga of a fake source with chapters c1...c6, stored newest first (as sources give them),
    /// and its own download manager (queue not saved) paused by the user, so nothing really downloads and
    /// no global queue or setting is touched. Cleans everything up afterwards.
    private func withLibraryManga(
        key: String,
        target: Int,
        _ body: (AidokuRunner.Manga, [AidokuRunner.Chapter], DownloadManager) async throws -> Void
    ) async throws {
        let manga = AidokuRunner.Manga(sourceKey: "downloadaheadtest", key: key, title: "Descarga adelantada \(key)")
        let newestFirst: [AidokuRunner.Chapter] = (1...6).reversed().map {
            .init(key: "c\($0)", chapterNumber: Float($0))
        }
        let manager = DownloadManager(queueStateKey: nil)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: newestFirst)
        DownloadAheadSetting.set(target, for: manga.identifier)
        await manager.pauseDownloads(byUser: true)
        do {
            try await body(manga, newestFirst, manager)
        } catch {
            Issue.record(error)
        }
        await manager.cancelDownloads(for: newestFirst.map {
            ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
        })
        await MangaManager.shared.removeFromLibrary(mangaId: manga.identifier)
        #expect(DownloadAheadSetting.get(for: manga.identifier) == 0) // removed with the manga
        DownloadManager.directory.appendingPathComponent(manga.sourceKey).appendingPathComponent(manga.key).removeItem()
    }

    private func status(_ manager: DownloadManager, _ manga: AidokuRunner.Manga, _ chapterKey: String) -> DownloadStatus {
        manager.getDownloadStatus(for: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapterKey))
    }

    @Test func ensureQueuesInReadingOrderWithWifi() async throws {
        try await withLibraryManga(key: "44", target: 2) { manga, _, manager in
            #expect(await manager.ensureAheadDownloaded(manga: manga, connection: .cellular, onlyOnWifi: true).isEmpty)
            let queued = await manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: true)
            #expect(queued.map(\.key) == ["c1", "c2"]) // oldest first, though stored newest first
            #expect(status(manager, manga, "c1") == .queued)
            #expect(status(manager, manga, "c3") == .none)
            // without the Wi-Fi rule, mobile data is fine; nothing new to queue now
            DownloadAheadSetting.set(3, for: manga.identifier)
            #expect(await manager.ensureAheadDownloaded(manga: manga, connection: .cellular, onlyOnWifi: false).map(\.key) == ["c3"])
        }
    }

    @Test func automaticTriggerKeepsAUserPausedQueuePaused() async throws {
        try await withLibraryManga(key: "45", target: 3) { manga, _, manager in
            #expect(await manager.isQueuePausedByUser())
            let queued = await manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false)
            #expect(queued.count == 3)
            #expect(await manager.isQueuePausedByUser()) // queued, not resumed
            #expect(await manager.downloadQueue.isPaused())
            #expect(status(manager, manga, "c1") == .queued)
        }
    }

    @Test func failedDownloadIsQueuedAgain() async throws {
        try await withLibraryManga(key: "46", target: 2) { manga, _, manager in
            // what DownloadQueue.downloadFailed leaves: out of the queue, a tmp folder with the failure marker
            let tmp = DownloadManager.directory
                .appendingPathComponent(manga.sourceKey)
                .appendingPathComponent(manga.key)
                .appendingPathComponent("\(DownloadCache.tmpDirectoryPrefix)c1")
            tmp.createDirectory()
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(DownloadCache.failureMarkerName).path, contents: Data())
            #expect(status(manager, manga, "c1") == .failed)
            let queued = await manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false)
            #expect(queued.map(\.key) == ["c1", "c2"])
            #expect(status(manager, manga, "c1") == .queued)
        }
    }

    @Test func oneRetryPerTrigger() {
        let statuses: [(key: String, status: DownloadStatus)] = [
            ("c1", .failed), ("c2", .failed), ("c3", .queued), ("c4", .finished), ("c5", .none)
        ]
        // first pass of a trigger: both failed chapters are missing (queued again)
        let first = DownloadAheadPlanner.split(statuses: statuses, retried: [])
        #expect(first.queued == ["c3"])
        #expect(first.downloaded == ["c4"])
        // c1 was queued again by this trigger and failed again: not queued a second time
        let second = DownloadAheadPlanner.split(statuses: statuses, retried: ["c1"])
        #expect(second.queued == ["c1", "c3"])
        #expect(!second.queued.contains("c2"))
    }

    @Test func concurrentTriggersQueueEachChapterOnce() async throws {
        try await withLibraryManga(key: "47", target: 3) { manga, _, manager in
            async let first = manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false)
            async let second = manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false)
            async let third = manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false)
            let all = await (first + second + third).map(\.key)
            #expect(all.sorted() == ["c1", "c2", "c3"])
            let inQueue = await manager.getDownloadQueue()[manga.sourceKey]?
                .filter { $0.chapterIdentifier.mangaKey == manga.key }
                .map(\.chapterIdentifier.chapterKey) ?? []
            #expect(inQueue.sorted() == ["c1", "c2", "c3"])
        }
    }

    @Test func ensureDoesNothingWhenOff() async throws {
        try await withLibraryManga(key: "48", target: 0) { manga, _, manager in
            #expect(await manager.ensureAheadDownloaded(manga: manga, connection: .wifi, onlyOnWifi: false).isEmpty)
            #expect(status(manager, manga, "c1") == .none)
        }
    }

    private func addFakeTrack(_ tracker: FakePageTracker, id: String, manga: AidokuRunner.Manga) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            _ = CoreDataManager.shared.createTrack(id: id, trackerId: tracker.id, mangaId: manga.identifier, title: nil, context: context)
            try? context.save()
        }
    }

    private func removeFakeTrack(_ tracker: FakePageTracker, manga: AidokuRunner.Manga) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeTrack(trackerId: tracker.id, mangaId: manga.identifier, context: context)
            try? context.save()
        }
    }

    @Test func chaptersReadOnAnotherDeviceMoveTheWindow() async throws {
        try await withLibraryManga(key: "49", target: 2) { manga, newestFirst, manager in
            let tracker = FakePageTracker(progress: ["c1": .init(completed: true, page: 20, date: .now)])
            await addFakeTrack(tracker, id: "fake-49", manga: manga)
            await TrackerManager.shared.syncPageTrackerHistory(
                manga: manga,
                chapters: newestFirst,
                trackerLookup: { $0 == tracker.id ? tracker : nil },
                downloadAhead: { await manager.ensureAheadDownloaded(mangaId: $0, onlyOnWifi: false) }
            )
            // the trigger runs on its own: wait for it (at most 5 s)
            var second = status(manager, manga, "c2")
            for _ in 0..<100 where second != .queued {
                try await Task.sleep(nanoseconds: 50_000_000)
                second = status(manager, manga, "c2")
            }
            // c1 read elsewhere: the window is c2, c3
            #expect(second == .queued)
            #expect(status(manager, manga, "c3") == .queued)
            #expect(status(manager, manga, "c1") == .none)
            #expect(status(manager, manga, "c4") == .none)
            await removeFakeTrack(tracker, manga: manga)
        }
    }

    @Test func syncDoesNotWaitForTheTrigger() async throws {
        try await withLibraryManga(key: "52", target: 2) { manga, newestFirst, _ in
            let tracker = FakePageTracker(progress: ["c1": .init(completed: true, page: 20, date: .now)])
            await addFakeTrack(tracker, id: "fake-52", manga: manga)
            let triggered = TriggerFlag()
            let start = Date()
            await TrackerManager.shared.syncPageTrackerHistory(
                manga: manga,
                chapters: newestFirst,
                trackerLookup: { $0 == tracker.id ? tracker : nil },
                downloadAhead: { _ in
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // a slow trigger
                    await triggered.set()
                }
            )
            let elapsed = Date().timeIntervalSince(start)
            #expect(elapsed < 1.5) // details, refresh and .historySet don't wait for it
            var done = await triggered.value
            for _ in 0..<100 where !done {
                try await Task.sleep(nanoseconds: 50_000_000)
                done = await triggered.value
            }
            #expect(done) // but it runs
            await removeFakeTrack(tracker, manga: manga)
        }
    }

    @Test func noQueueingIfWifiIsLostBeforeQueueing() async throws {
        try await withLibraryManga(key: "53", target: 2) { manga, _, manager in
            let checks = CheckCounter()
            // Wi-Fi for the first checks (trigger start, pending-run start), lost right before queueing
            let queued = await manager.ensureAheadDownloaded(
                manga: manga,
                onlyOnWifi: true,
                connectionProvider: { checks.next() <= 2 ? .wifi : .cellular }
            )
            #expect(queued.isEmpty)
            #expect(status(manager, manga, "c1") == .none)
        }
    }

    @Test func settingIsRemovedWithSeveralMangaAndRestoredOnUndo() async throws {
        let mangas = (60...61).map { AidokuRunner.Manga(sourceKey: "downloadaheadtest", key: "\($0)", title: "Descarga adelantada \($0)") }
        let chapters: [AidokuRunner.Chapter] = [.init(key: "c1", chapterNumber: 1)]
        for manga in mangas {
            await MangaManager.shared.addToLibrary(manga: manga, chapters: chapters)
            DownloadAheadSetting.set(3, for: manga.identifier)
        }
        let first = mangas[0].identifier
        // what LibraryViewController keeps for undo, read before removing
        let snapshot = await CoreDataManager.shared.container.performBackgroundTask { context in
            LibraryViewController.LibraryRemovalSnapshot.make(mangaId: first, context: context)
        }
        await MangaManager.shared.removeFromLibrary(mangaIds: mangas.map(\.identifier))
        #expect(DownloadAheadSetting.get(for: mangas[0].identifier) == 0)
        #expect(DownloadAheadSetting.get(for: mangas[1].identifier) == 0)

        let removed = try #require(snapshot)
        #expect(removed.downloadAhead == 3)
        await MangaManager.shared.restoreToLibrary(
            manga: removed.manga,
            chapters: removed.chapters,
            trackItems: removed.trackItems,
            categories: removed.categories,
            downloadAhead: removed.downloadAhead
        )
        #expect(DownloadAheadSetting.get(for: first) == 3)
        await MangaManager.shared.removeFromLibrary(mangaId: first)
    }

    @Test func migrationDoesNotOverwriteTheDestination() {
        let old = MangaIdentifier(sourceKey: "downloadaheadtest", mangaKey: "70")
        let new = MangaIdentifier(sourceKey: "downloadaheadtest2", mangaKey: "71")
        defer {
            DownloadAheadSetting.set(0, for: old)
            DownloadAheadSetting.set(0, for: new)
        }
        DownloadAheadSetting.set(5, for: old)
        DownloadAheadSetting.set(2, for: new)
        DownloadAheadSetting.migrate(from: old, to: new, copy: false)
        #expect(DownloadAheadSetting.get(for: new) == 2)
        #expect(DownloadAheadSetting.get(for: old) == 0)
    }
}

private actor TriggerFlag {
    private(set) var value = false
    func set() { value = true }
}

/// Counts connection checks (thread-safe).
private final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// A page tracker that reports fixed progress.
private final class FakePageTracker: PageTracker, @unchecked Sendable {
    struct Unsupported: Error {}
    let id = "test.fakepagetracker"
    let name = "Fake"
    let icon: PlatformImage? = nil
    let isLoggedIn = true
    let progress: [String: ChapterReadProgress]

    init(progress: [String: ChapterReadProgress]) {
        self.progress = progress
    }

    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws {}
    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress] {
        progress
    }
    func getTrackerInfo() async throws -> TrackerInfo { throw Unsupported() }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { throw Unsupported() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}
