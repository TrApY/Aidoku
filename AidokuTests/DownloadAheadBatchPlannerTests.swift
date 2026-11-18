//
//  DownloadAheadBatchPlannerTests.swift
//  AidokuTests
//
//  SUWA-28 B1: «descarga adelantada» por tandas in the planner. With `refillAt: X`, nothing is queued while more
//  than X chapters of the window (the next N not completed after the last completed one) are downloaded or
//  queued; at X or fewer, the window is filled up. `refillAt: nil` is the continuous mode (as before).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite struct DownloadAheadBatchPlannerTests {
    /// Chapters 1...count in reading order (oldest first), keys "c1", "c2", …
    private func chapters(_ count: Int, locked: Set<Int> = []) -> [AidokuRunner.Chapter] {
        (1...count).map { .init(key: "c\($0)", chapterNumber: Float($0), locked: locked.contains($0)) }
    }

    private func read(_ numbers: [Int]) -> [String: (page: Int, date: Int)] {
        var history: [String: (page: Int, date: Int)] = [:]
        for number in numbers {
            history["c\(number)"] = (page: -1, date: number)
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
        scanlators: [String] = [],
        refillAt: Int?
    ) -> [String] {
        DownloadAheadPlanner.chaptersToQueue(
            chapters: chapters,
            readingHistory: history,
            downloaded: downloaded,
            queued: queued,
            target: target,
            language: language,
            scanlators: scanlators,
            refillAt: refillAt
        ).map(\.key)
    }

    /// N = 5, X = 1: two of the window downloaded → nothing; one → the other four; none → five.
    @Test func refillsOnlyAtTheThreshold() {
        let all = chapters(12)
        #expect(plan(all, read: read([2]), downloaded: ["c3", "c4"], target: 5, refillAt: 1).isEmpty)
        #expect(plan(all, read: read([2]), downloaded: ["c3"], target: 5, refillAt: 1) == ["c4", "c5", "c6", "c7"])
        #expect(plan(all, read: read([2]), target: 5, refillAt: 1) == ["c3", "c4", "c5", "c6", "c7"])
        // downloads outside the window don't count (c1 read, c9 beyond the window)
        #expect(plan(all, read: read([2]), downloaded: ["c1", "c3", "c9"], target: 5, refillAt: 1) == ["c4", "c5", "c6", "c7"])
    }

    /// X = 0: one left → nothing; none left → five.
    @Test func zeroWaitsUntilNothingIsLeft() {
        let all = chapters(12)
        #expect(plan(all, read: read([2]), downloaded: ["c5"], target: 5, refillAt: 0).isEmpty)
        #expect(plan(all, read: read([2]), target: 5, refillAt: 0) == ["c3", "c4", "c5", "c6", "c7"])
    }

    /// N = 3, X = 4 (effective 2): as the continuous mode, two downloaded → the third.
    @Test func thresholdNotBelowTheTargetIsContinuous() {
        let all = chapters(12)
        #expect(plan(all, read: read([2]), downloaded: ["c3", "c4"], target: 3, refillAt: 4) == ["c5"])
        #expect(plan(all, read: read([2]), downloaded: ["c3", "c4"], target: 3, refillAt: 2) == ["c5"])
        #expect(plan(all, read: read([2]), downloaded: ["c3", "c4"], target: 3, refillAt: nil) == ["c5"])
    }

    /// Queued chapters count as downloaded.
    @Test func queuedChaptersCount() {
        let all = chapters(12)
        #expect(plan(all, read: read([2]), downloaded: ["c3"], queued: ["c6"], target: 5, refillAt: 1).isEmpty)
        #expect(plan(all, read: read([2]), queued: ["c3", "c4"], target: 5, refillAt: 1).isEmpty)
        #expect(plan(all, read: read([2]), queued: ["c4"], target: 5, refillAt: 1) == ["c3", "c5", "c6", "c7"])
    }

    /// Only the filtered window counts: other languages/scanlators and locked chapters don't.
    @Test func onlyTheFilteredWindowCounts() {
        let all: [AidokuRunner.Chapter] = (1...8).flatMap { number -> [AidokuRunner.Chapter] in
            [
                .init(key: "\(number)-en", chapterNumber: Float(number), scanlators: ["A"], language: "en"),
                .init(key: "\(number)-es-a", chapterNumber: Float(number), scanlators: ["A"], language: "es"),
                .init(key: "\(number)-es-b", chapterNumber: Float(number), scanlators: ["B"], language: "es", locked: number == 3)
            ]
        }
        // window in Spanish/B with 3 ahead: 1, 2, 4 (3 is locked)
        #expect(plan(all, target: 3, language: "es", scanlators: ["B"], refillAt: 1) == ["1-es-b", "2-es-b", "4-es-b"])
        // English and A downloads, and the locked chapter, are not in the window: still a full refill
        let outside: Set<String> = ["1-en", "2-en", "1-es-a", "2-es-a", "3-es-b"]
        #expect(plan(all, downloaded: outside, target: 3, language: "es", scanlators: ["B"], refillAt: 1) == ["1-es-b", "2-es-b", "4-es-b"])
        // one of the window downloaded (at the threshold): the other two
        #expect(plan(all, downloaded: outside.union(["2-es-b"]), target: 3, language: "es", scanlators: ["B"], refillAt: 1) == ["1-es-b", "4-es-b"])
        // two of the window: nothing
        #expect(plan(all, downloaded: ["1-es-b", "4-es-b"], target: 3, language: "es", scanlators: ["B"], refillAt: 1).isEmpty)
    }

    /// The status overload: a failed chapter is missing (doesn't count) unless this trigger already queued it again.
    @Test func failedChaptersCountAsBefore() {
        let all = chapters(12)
        let status: [String: DownloadStatus] = ["c3": .finished, "c4": .failed]
        func plan(retried: Set<String>) -> [String] {
            DownloadAheadPlanner.chaptersToQueue(
                chapters: all, readingHistory: read([2]), target: 5, retried: retried, refillAt: 1,
                status: { status[$0] ?? DownloadStatus.none }
            ).map(\.key)
        }
        #expect(plan(retried: []) == ["c4", "c5", "c6", "c7"])
        #expect(plan(retried: ["c4"]).isEmpty) // failed again after this trigger queued it: counts as queued
    }

    /// The continuous mode is exactly «threshold = N - 1»: same result in random cases, with both overloads.
    @Test func continuousIsTargetMinusOne() {
        var seed: UInt64 = 28
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        let statuses: [DownloadStatus] = [.none, .finished, .queued, .downloading, .paused, .failed, .cancelled]
        for _ in 0..<500 {
            let count = next(30)
            let chapters: [AidokuRunner.Chapter] = (0..<count).map {
                .init(key: "c\($0)", chapterNumber: Float($0), language: next(5) == 0 ? "en" : "es", locked: next(8) == 0)
            }
            var history: [String: (page: Int, date: Int)] = [:]
            for chapter in chapters where next(3) == 0 {
                history[chapter.key] = (page: next(2) == 0 ? -1 : 4, date: 0)
            }
            var status: [String: DownloadStatus] = [:]
            for chapter in chapters { status[chapter.key] = statuses[next(statuses.count)] }
            let retried = Set(chapters.filter { _ in next(6) == 0 }.map(\.key))
            let target = [1, 2, 3, 5, 10][next(5)]
            let language: String? = next(3) == 0 ? "es" : nil
            func run(_ refillAt: Int?) -> [String] {
                DownloadAheadPlanner.chaptersToQueue(
                    chapters: chapters, readingHistory: history, target: target, retried: retried,
                    language: language, refillAt: refillAt, status: { status[$0] ?? DownloadStatus.none }
                ).map(\.key)
            }
            #expect(run(nil) == run(target - 1))
            #expect(run(nil) == run(target + 3))
            let (downloaded, queued) = DownloadAheadPlanner.split(
                statuses: chapters.map { ($0.key, status[$0.key] ?? DownloadStatus.none) }, retried: retried
            )
            let sets = DownloadAheadPlanner.chaptersToQueue(
                chapters: chapters, readingHistory: history, downloaded: downloaded, queued: queued,
                target: target, language: language, refillAt: target - 1
            ).map(\.key)
            #expect(sets == run(nil))
            // and a batch threshold below it gives the same chapters or nothing
            let batch = run(next(target))
            #expect(batch.isEmpty || batch == run(nil))
        }
    }
}
