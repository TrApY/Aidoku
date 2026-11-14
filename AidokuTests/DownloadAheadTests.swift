//
//  DownloadAheadTests.swift
//  AidokuTests
//

import AidokuRunner
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
    /// and a paused queue so nothing really downloads. Cleans everything up afterwards.
    private func withLibraryManga(
        key: String,
        target: Int,
        _ body: (AidokuRunner.Manga, [AidokuRunner.Chapter]) async throws -> Void
    ) async throws {
        let manga = AidokuRunner.Manga(sourceKey: "downloadaheadtest", key: key, title: "Descarga adelantada \(key)")
        let newestFirst: [AidokuRunner.Chapter] = (1...6).reversed().map {
            .init(key: "c\($0)", chapterNumber: Float($0))
        }
        let onlyOnWifi = AppSettings.downloads.downloadOnlyOnWifi.get()
        let wasPaused = await DownloadManager.shared.isQueuePausedByUser()
        await MangaManager.shared.addToLibrary(manga: manga, chapters: newestFirst)
        DownloadAheadSetting.set(target, for: manga.identifier)
        await DownloadManager.shared.pauseDownloads()
        do {
            try await body(manga, newestFirst)
        } catch {
            Issue.record(error)
        }
        await DownloadManager.shared.cancelDownloads(for: newestFirst.map {
            ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key)
        })
        await MangaManager.shared.removeFromLibrary(mangaId: manga.identifier)
        #expect(DownloadAheadSetting.get(for: manga.identifier) == 0) // removed with the manga
        DownloadManager.directory.appendingPathComponent(manga.sourceKey).removeItem()
        AppSettings.downloads.downloadOnlyOnWifi.set(onlyOnWifi)
        if !wasPaused {
            await DownloadManager.shared.resumeDownloads()
        }
    }

    private func status(_ manga: AidokuRunner.Manga, _ chapterKey: String) -> DownloadStatus {
        DownloadManager.shared.getDownloadStatus(for: .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapterKey))
    }

    @Test func ensureQueuesInReadingOrderWithWifi() async throws {
        try await withLibraryManga(key: "44", target: 2) { manga, _ in
            AppSettings.downloads.downloadOnlyOnWifi.set(true)
            #expect(await DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .cellular).isEmpty)
            let queued = await DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi)
            #expect(queued.map(\.key) == ["c1", "c2"]) // oldest first, though stored newest first
            #expect(status(manga, "c1") == .queued)
            #expect(status(manga, "c3") == .none)
            // without the Wi-Fi rule, mobile data is fine; nothing new to queue now
            AppSettings.downloads.downloadOnlyOnWifi.set(false)
            DownloadAheadSetting.set(3, for: manga.identifier)
            #expect(await DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .cellular).map(\.key) == ["c3"])
        }
    }

    @Test func automaticTriggerKeepsAPausedQueuePaused() async throws {
        try await withLibraryManga(key: "45", target: 3) { manga, _ in
            AppSettings.downloads.downloadOnlyOnWifi.set(false)
            #expect(await DownloadManager.shared.isQueuePausedByUser())
            let queued = await DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi)
            #expect(queued.count == 3)
            #expect(await DownloadManager.shared.isQueuePausedByUser()) // queued, not resumed
            #expect(status(manga, "c1") == .queued)
        }
    }

    @Test func failedDownloadIsQueuedAgain() async throws {
        try await withLibraryManga(key: "46", target: 2) { manga, _ in
            AppSettings.downloads.downloadOnlyOnWifi.set(false)
            // what DownloadQueue.downloadFailed leaves: out of the queue, a tmp folder with the failure marker
            let tmp = DownloadManager.directory
                .appendingPathComponent(manga.sourceKey)
                .appendingPathComponent(manga.key)
                .appendingPathComponent("\(DownloadCache.tmpDirectoryPrefix)c1")
            tmp.createDirectory()
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(DownloadCache.failureMarkerName).path, contents: Data())
            #expect(status(manga, "c1") == .failed)
            let queued = await DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi)
            #expect(queued.map(\.key) == ["c1", "c2"])
            #expect(status(manga, "c1") == .queued)
        }
    }

    @Test func concurrentTriggersQueueEachChapterOnce() async throws {
        try await withLibraryManga(key: "47", target: 3) { manga, _ in
            AppSettings.downloads.downloadOnlyOnWifi.set(false)
            async let first = DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi)
            async let second = DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi)
            async let third = DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi)
            let all = await (first + second + third).map(\.key)
            #expect(all.sorted() == ["c1", "c2", "c3"])
            let inQueue = await DownloadManager.shared.getDownloadQueue()[manga.sourceKey]?
                .filter { $0.chapterIdentifier.mangaKey == manga.key }
                .map(\.chapterIdentifier.chapterKey) ?? []
            #expect(inQueue.sorted() == ["c1", "c2", "c3"])
        }
    }

    @Test func ensureDoesNothingWhenOff() async throws {
        try await withLibraryManga(key: "48", target: 0) { manga, _ in
            AppSettings.downloads.downloadOnlyOnWifi.set(false)
            #expect(await DownloadManager.shared.ensureAheadDownloaded(manga: manga, connection: .wifi).isEmpty)
            #expect(status(manga, "c1") == .none)
        }
    }
}
