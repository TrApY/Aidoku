//
//  PageTrackerQueueTests.swift
//  AidokuTests
//

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
}
