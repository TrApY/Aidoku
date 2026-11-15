//
//  PageTrackerQueueTests.swift
//  AidokuTests
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

struct PageTrackerQueueTests {
    private func update(_ chapter: String, page: Int, fails: Int = 0) -> PageTrackUpdate {
        .init(
            trackerId: "suwayomi",
            trackId: "54",
            chapterId: .init(sourceKey: "s", mangaKey: "m", chapterKey: chapter),
            progress: .init(completed: false, page: page),
            failCount: fails
        )
    }

    private func pages(_ updates: [PageTrackUpdate]) -> [String] {
        updates.map { "\($0.chapterId.chapterKey):\($0.progress.page):\($0.failCount)" }
    }

    @Test func updatesQueuedWhileABatchIsSentAreKept() {
        let sent = [update("c1", page: 3)]
        // while c1:3 was on the network, an immediate save queued c1:7 and c2:1
        let current = [update("c1", page: 7), update("c2", page: 1)]
        let remaining = TrackerManager.remainingPageUpdates(current: current, sent: sent, failed: [])
        #expect(pages(remaining) == ["c1:7:0", "c2:1:0"])
    }

    @Test func sentUpdatesLeaveAndFailedOnesStay() {
        let sent = [update("c1", page: 3), update("c2", page: 4)]
        let failed = [update("c2", page: 4, fails: 1)]
        let remaining = TrackerManager.remainingPageUpdates(current: sent, sent: sent, failed: failed)
        #expect(pages(remaining) == ["c2:4:1"])
    }

    @Test func aNewerUpdateWinsOverARetry() {
        let sent = [update("c1", page: 3)]
        let failed = [update("c1", page: 3, fails: 1)]
        let current = [update("c1", page: 9)]
        let remaining = TrackerManager.remainingPageUpdates(current: current, sent: sent, failed: failed)
        #expect(pages(remaining) == ["c1:9:0"])
    }

    @Test func aCallThatWaitedSendsWhatWasQueuedMeanwhile() async throws {
        let tracker = SlowPageTracker()
        let manager = TrackerManager(stateKey: nil, pageTrackerLookup: { $0 == tracker.id ? tracker : nil })
        let first = PageTrackUpdate(
            trackerId: tracker.id, trackId: "1",
            chapterId: .init(sourceKey: "s", mangaKey: "m", chapterKey: "c1"),
            progress: .init(completed: false, page: 3)
        )
        let second = PageTrackUpdate(
            trackerId: tracker.id, trackId: "1",
            chapterId: .init(sourceKey: "s", mangaKey: "m", chapterKey: "c1"),
            progress: .init(completed: false, page: 7)
        )
        await manager.sendPageUpdates([first]) // a batch on the network (slow)
        try await Task.sleep(nanoseconds: 50_000_000)
        await manager.sendPageUpdates([second]) // queued meanwhile: waits for the batch, then sends it
        await manager.waitForPendingPageUpdates()
        #expect(await tracker.sentPages == [3, 7])
        #expect(await manager.pendingPageUpdates.isEmpty)
    }
}

/// A page tracker whose updates take a while.
private final class SlowPageTracker: PageTracker, @unchecked Sendable {
    struct Unsupported: Error {}
    let id = "test.slowpagetracker"
    let name = "Slow"
    let icon: PlatformImage? = nil
    let isLoggedIn = true
    private let log = SentLog()
    var sentPages: [Int] { get async { await log.pages } }

    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        await log.add(progress.page)
    }
    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress] { [:] }
    func getTrackerInfo() async throws -> TrackerInfo { throw Unsupported() }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { throw Unsupported() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}

private actor SentLog {
    private(set) var pages: [Int] = []
    func add(_ page: Int) { pages.append(page) }
}
