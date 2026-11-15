//
//  MigrationHistoryTests.swift
//  AidokuTests
//
//  How the reading history goes to the chapters of the new manga when migrating.
//

import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct MigrationHistoryTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    private func chapters(_ numbers: [Float], volume: Float? = nil) -> [AidokuRunner.Chapter] {
        numbers.map { .init(key: "n\($0)", chapterNumber: $0, volumeNumber: volume) }
    }

    @Test func onlyCompletedChaptersCountAsRead() {
        let old: [MigrationHistory.Entry] = [
            .init(chapter: 1, completed: true, dateRead: day(1)),
            .init(chapter: 2, completed: true, dateRead: day(2)),
            .init(chapter: 3, completed: false, progress: 5, total: 20, dateRead: day(3)) // left half way
        ]
        let plan = MigrationHistory.plan(old: old, newChapters: chapters([5, 4, 3, 2, 1]), now: now)
        #expect(plan.completed == [.init(chapterKey: "n2.0", date: day(2)), .init(chapterKey: "n1.0", date: day(1))])
        #expect(plan.highestRead == 2)
        // the unfinished chapter keeps its page and date, not marked
        #expect(plan.inProgress == [.init(chapterKey: "n3.0", progress: 5, total: 20, date: day(3), scrollPosition: nil)])
    }

    @Test func chaptersWithoutAPairGetTheLatestReadingDate() {
        let old: [MigrationHistory.Entry] = [
            .init(chapter: 1, completed: true, dateRead: day(1)),
            .init(chapter: 3, completed: true, dateRead: day(5)),
            .init(chapter: 4, completed: false, progress: 2, total: 10, dateRead: day(9))
        ]
        let plan = MigrationHistory.plan(old: old, newChapters: chapters([3, 2, 1]), now: now)
        // 2 was not in the old history: the most recent date of the old reading, not now
        #expect(plan.completed == [
            .init(chapterKey: "n3.0", date: day(5)),
            .init(chapterKey: "n2.0", date: day(9)),
            .init(chapterKey: "n1.0", date: day(1))
        ])
        #expect(!plan.completed.contains { $0.date == now })
        #expect(plan.inProgress.isEmpty) // the new source has no chapter 4
    }

    @Test func decimalChapters() {
        let old: [MigrationHistory.Entry] = [
            .init(chapter: 10, completed: true, dateRead: day(1)),
            .init(chapter: 10.5, completed: true, dateRead: day(2)),
            .init(chapter: 11, completed: false, progress: 3, total: 30, dateRead: day(3), scrollPosition: 0.25)
        ]
        let plan = MigrationHistory.plan(old: old, newChapters: chapters([12, 11, 10.5, 10]), now: now)
        #expect(plan.completed.map(\.chapterKey) == ["n10.5", "n10.0"])
        #expect(plan.completed.map(\.date) == [day(2), day(1)])
        #expect(plan.inProgress == [.init(chapterKey: "n11.0", progress: 3, total: 30, date: day(3), scrollPosition: 0.25)])
        // read up to 10: 10.5 is not marked
        let upTo10 = MigrationHistory.plan(old: [.init(chapter: 10, completed: true, dateRead: day(1))], newChapters: chapters([10.5, 10]), now: now)
        #expect(upTo10.completed.map(\.chapterKey) == ["n10.0"])
    }

    @Test func volumesWhenThereAreNoChapterNumbers() {
        let old: [MigrationHistory.Entry] = [
            .init(chapter: nil, volume: 1, completed: true, dateRead: day(1)),
            .init(chapter: nil, volume: 2, completed: true, dateRead: day(2)),
            .init(chapter: nil, volume: 3, completed: false, progress: 4, total: 40, dateRead: day(3)) // started, not read
        ]
        let new: [AidokuRunner.Chapter] = [3, 2, 1].map { .init(key: "v\($0)", volumeNumber: Float($0)) }
        let plan = MigrationHistory.plan(old: old, newChapters: new, now: now)
        #expect(plan.highestRead == 2)
        #expect(plan.completed == [.init(chapterKey: "v2", date: day(2)), .init(chapterKey: "v1", date: day(1))])
    }

    @Test func theUnfinishedChapterGoesToTheSameVolume() {
        let old: [MigrationHistory.Entry] = [
            .init(chapter: 5, volume: 1, completed: false, progress: 7, total: 12, dateRead: day(4))
        ]
        let new: [AidokuRunner.Chapter] = [
            .init(key: "a", chapterNumber: 5, volumeNumber: 2),
            .init(key: "b", chapterNumber: 5, volumeNumber: 1)
        ]
        let plan = MigrationHistory.plan(old: old, newChapters: new, now: now)
        #expect(plan.completed.isEmpty) // nothing completed: nothing marked
        #expect(plan.highestRead == nil)
        #expect(plan.inProgress == [.init(chapterKey: "b", progress: 7, total: 12, date: day(4), scrollPosition: nil)])
        // without volumes on one side, the number alone
        let noVolume = MigrationHistory.plan(old: old, newChapters: [.init(key: "c", chapterNumber: 5)], now: now)
        #expect(noVolume.inProgress.map(\.chapterKey) == ["c"])
    }

    @Test func aReadChapterIsNotAlsoInProgress() {
        // re-reading chapter 1 after finishing 2: chapter 1 is read (up to 2), its page is not carried
        let old: [MigrationHistory.Entry] = [
            .init(chapter: 1, completed: false, progress: 3, total: 10, dateRead: day(6)),
            .init(chapter: 2, completed: true, dateRead: day(5))
        ]
        let plan = MigrationHistory.plan(old: old, newChapters: chapters([2, 1]), now: now)
        #expect(plan.completed.map(\.chapterKey) == ["n2.0", "n1.0"])
        #expect(plan.inProgress.isEmpty)
    }
}
