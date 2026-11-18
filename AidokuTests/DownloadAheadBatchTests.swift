//
//  DownloadAheadBatchTests.swift
//  AidokuTests
//
//  SUWA-28 B2: «descarga adelantada» por tandas through the real `ensureAheadDownloaded`. The global setting is
//  read from the manager's own UserDefaults (a test suite, removed afterwards), so other suites never see it.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct DownloadAheadBatchTests {
    private static let sourceKey = "downloadbatchestest"

    /// Chapters 1...count newest first (as sources give them).
    private static func newestFirst(_ count: Int) -> [AidokuRunner.Chapter] {
        (1...count).reversed().map { .init(key: "c\($0)", chapterNumber: Float($0)) }
    }

    struct Context {
        let manga: AidokuRunner.Manga
        let manager: DownloadManager
        let defaults: UserDefaults

        func chapterId(_ number: Int) -> ChapterIdentifier {
            .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c\(number)")
        }

        /// What a finished download leaves on disk: the chapter's folder.
        func markDownloaded(_ numbers: [Int]) {
            for number in numbers {
                DownloadManager.directory
                    .appendingPathComponent(manga.sourceKey)
                    .appendingPathComponent(manga.key)
                    .appendingPathComponent("c\(number)")
                    .createDirectory()
            }
        }

        /// Completed, as the reader or «mark as read» save it (without the global trigger: the test runs its own).
        func complete(_ numbers: [Int]) async {
            await DataRepositories.shared.history.markCompleted(numbers.map(chapterId), date: .now)
        }

        func batches(_ on: Bool, refillAt: Int = 1) {
            defaults.set(on, forKey: AppSettings.downloads.downloadAheadBatches.key)
            defaults.set(refillAt, forKey: AppSettings.downloads.downloadAheadRefillAt.key)
        }

        func trigger(ignoringBatches: Bool = false) async -> [String] {
            await manager.ensureAheadDownloaded(
                manga: manga, ignoringBatches: ignoringBatches, connection: .wifi, onlyOnWifi: false
            ).map(\.key)
        }

        /// The manga's chapters in the manager's queue, in queue order.
        func queued() async -> [String] {
            await manager.getDownloadQueue()[manga.sourceKey]?
                .filter { $0.chapterIdentifier.mangaKey == manga.key }
                .map(\.chapterIdentifier.chapterKey) ?? []
        }
    }

    /// A library manga of a fake source with `count` chapters and «descarga adelantada» of `target`, its own
    /// download manager (queue not saved, paused by the user: nothing really downloads) and its own settings.
    /// Cleans everything up afterwards.
    private func withLibraryManga(
        key: String,
        count: Int = 12,
        target: Int,
        _ body: (Context) async throws -> Void
    ) async throws {
        let manga = AidokuRunner.Manga(sourceKey: Self.sourceKey, key: key, title: "Por tandas \(key)")
        let suite = "DownloadAheadBatchTests.\(key)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let manager = DownloadManager(queueStateKey: nil, downloadAheadDefaults: defaults)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: Self.newestFirst(count))
        DownloadAheadSetting.set(target, for: manga.identifier)
        await manager.pauseDownloads(byUser: true)
        let context = Context(manga: manga, manager: manager, defaults: defaults)
        do {
            try await body(context)
        } catch {
            Issue.record(error)
        }
        let ids = (1...max(count, 20)).map(context.chapterId)
        await manager.cancelDownloads(for: ids)
        await DataRepositories.shared.history.remove(chapters: ids)
        DownloadAheadSetting.set(0, for: manga.identifier)
        await MangaManager.shared.removeFromLibrary(mangaId: manga.identifier)
        DownloadManager.directory.appendingPathComponent(manga.sourceKey).appendingPathComponent(manga.key).removeItem()
        defaults.removePersistentDomain(forName: suite)
    }

    /// The setting the executor reads: nil in the continuous mode, min(X, N - 1) in the batch mode.
    @Test func refillThresholdFromTheSettings() throws {
        let suite = "DownloadAheadBatchTests.ajustes"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        #expect(DownloadAheadSetting.batchRefillAt(target: 5, defaults: defaults) == nil) // off by default
        defaults.set(true, forKey: AppSettings.downloads.downloadAheadBatches.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 5, defaults: defaults) == 1) // X = 1 by default
        defaults.set(3, forKey: AppSettings.downloads.downloadAheadRefillAt.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 5, defaults: defaults) == 3)
        #expect(DownloadAheadSetting.batchRefillAt(target: 3, defaults: defaults) == 2) // X >= N: N - 1, continuous
        #expect(DownloadAheadSetting.batchRefillAt(target: 1, defaults: defaults) == 0)
        // the settings stepper stores a Double
        defaults.set(2.0, forKey: AppSettings.downloads.downloadAheadRefillAt.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 5, defaults: defaults) == 2)
        defaults.set(0.0, forKey: AppSettings.downloads.downloadAheadRefillAt.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 5, defaults: defaults) == 0)
        // out of the stepper's range: kept within 0...4
        defaults.set(9, forKey: AppSettings.downloads.downloadAheadRefillAt.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 10, defaults: defaults) == 4)
        defaults.set(-2, forKey: AppSettings.downloads.downloadAheadRefillAt.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 10, defaults: defaults) == 0)
        defaults.set(false, forKey: AppSettings.downloads.downloadAheadBatches.key)
        #expect(DownloadAheadSetting.batchRefillAt(target: 5, defaults: defaults) == nil)
    }

    /// (1) X = 1, N = 5, five downloaded: completing 1, 2 and 3 queues nothing; completing 4 queues the next four,
    /// in reading order.
    @Test func batchRefillsWhenOneIsLeft() async throws {
        try await withLibraryManga(key: "1", target: 5) { context in
            context.batches(true, refillAt: 1)
            context.markDownloaded([1, 2, 3, 4, 5])
            for number in 1...3 {
                await context.complete([number])
                #expect(await context.trigger().isEmpty, "completado \(number)")
            }
            #expect(await context.queued().isEmpty)
            await context.complete([4])
            #expect(await context.trigger() == ["c6", "c7", "c8", "c9"])
            #expect(await context.queued() == ["c6", "c7", "c8", "c9"])
        }
    }

    /// (2) Batch mode off: as before, completing one queues one.
    @Test func continuousModeKeepsTheWindowFull() async throws {
        try await withLibraryManga(key: "2", target: 5) { context in
            context.batches(false, refillAt: 1)
            context.markDownloaded([1, 2, 3, 4, 5])
            await context.complete([1])
            #expect(await context.trigger() == ["c6"])
        }
    }

    /// (3) The number chosen by hand in the manga page fills up now, also in the batch mode.
    @Test func choosingTheNumberFillsUpNow() async throws {
        try await withLibraryManga(key: "3", target: 5) { context in
            context.batches(true, refillAt: 1)
            context.markDownloaded([1, 2])
            #expect(await context.trigger().isEmpty) // an automatic trigger waits
            #expect(await context.trigger(ignoringBatches: true) == ["c3", "c4", "c5"])
        }
    }

    /// (4) «Siguientes N sin leer» doesn't follow the batch mode.
    @Test func nextUnreadIgnoresTheBatchMode() async throws {
        try await withLibraryManga(key: "4", target: 5) { context in
            context.batches(true, refillAt: 1)
            context.markDownloaded([1, 2])
            await context.manager.downloadUnread(manga: context.manga, limit: 5, start: .unlessUserPaused)
            #expect(await context.queued() == ["c3", "c4", "c5"])
        }
    }

    /// (5) New chapters found by a refresh with three of five downloaded (X = 1): nothing; in the continuous
    /// mode the same trigger fills up.
    @Test func newChaptersDontRefillABatch() async throws {
        try await withLibraryManga(key: "5", count: 3, target: 5) { context in
            context.batches(true, refillAt: 1)
            context.markDownloaded([1, 2, 3])
            let runner = BatchRefreshRunner(chapters: Self.newestFirst(8))
            let source = AidokuRunner.Source(
                key: context.manga.sourceKey, name: "Tandas", version: 1, contentRating: .safe, runner: runner
            )
            let results = BatchTriggerResults()
            let manager = context.manager
            let manga = context.manga
            let viewModel = await MainActor.run {
                let viewModel = MangaView.ViewModel(source: source, manga: manga)
                viewModel.downloadAheadTrigger = { mangaId in
                    await results.add(await manager.ensureAheadDownloaded(mangaId: mangaId, onlyOnWifi: false).map(\.key))
                }
                return viewModel
            }
            await viewModel.refresh()
            let first = await results.wait(count: 1, seconds: 10)
            #expect(first == [[]])
            #expect(await context.queued().isEmpty)
            // the new chapters were stored: the continuous mode fills the window up
            context.batches(false)
            #expect(await context.trigger() == ["c4", "c5"])
        }
    }

    /// (6) N = 1 with X = 4: as the continuous mode.
    @Test func oneAheadIsContinuous() async throws {
        try await withLibraryManga(key: "6", target: 1) { context in
            context.batches(true, refillAt: 4)
            #expect(DownloadAheadSetting.batchRefillAt(target: 1, defaults: context.defaults) == 0)
            #expect(await context.trigger() == ["c1"])
            await context.complete([1])
            #expect(await context.trigger() == ["c2"])
            context.markDownloaded([2])
            await context.complete([2])
            #expect(await context.trigger() == ["c3"])
        }
    }
}

/// The manga page's source in the refresh test: its chapters can change between refreshes.
private final class BatchRefreshRunner: AidokuRunner.Runner, @unchecked Sendable {
    private let lock = NSLock()
    private var storedChapters: [AidokuRunner.Chapter]
    let features = AidokuRunner.SourceFeatures()

    init(chapters: [AidokuRunner.Chapter]) {
        storedChapters = chapters
    }

    var chapters: [AidokuRunner.Chapter] {
        get { lock.withLock { storedChapters } }
        set { lock.withLock { storedChapters = newValue } }
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        var manga = manga
        if needsChapters {
            manga.chapters = chapters
        }
        return manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }
}

/// What each «descarga adelantada» trigger queued.
private actor BatchTriggerResults {
    private(set) var results: [[String]] = []
    func add(_ keys: [String]) { results.append(keys) }

    func wait(count: Int, seconds: Double) async -> [[String]] {
        let deadline = Date().addingTimeInterval(seconds)
        while results.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return results
    }
}
