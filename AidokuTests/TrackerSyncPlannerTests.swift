//
//  TrackerSyncPlannerTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L11b (D-L11-6): the rules of the page trackers' sync, without a store. Each test is one rule of
//  TrackerManager.syncPageTrackerHistory as it was.
//

import Foundation
import Testing

@testable import Aidoku

struct TrackerSyncPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + n * 86_400) }

    private func plan(_ local: [String: TrackerSyncLocal], _ remote: [String: ChapterReadProgress]) -> TrackerSyncPlan {
        TrackerSyncPlanner.plan(local: local, remote: remote, now: now)
    }

    /// With local history, a tracker progress without a date is not compared: nothing (SUWA-12 F).
    @Test func localHistoryAndNoDateFromTheTrackerTouchesNothing() {
        let result = plan(
            ["c1": .init(completed: false, progress: 3, total: 10, dateRead: day(1))],
            ["c1": .init(completed: true, page: 0, date: nil)]
        )
        #expect(result == TrackerSyncPlan())
    }

    /// A tracker date not newer than the local one: nothing (equal included).
    @Test func aTrackerDateNotNewerThanTheLocalOneTouchesNothing() {
        for date in [day(1), day(2)] {
            let result = plan(
                ["c1": .init(completed: false, progress: 3, total: 10, dateRead: day(2))],
                ["c1": .init(completed: true, page: 0, date: date)]
            )
            #expect(result == TrackerSyncPlan(), "\(date)")
        }
    }

    /// Completed on the tracker and not here: complete with its date; the manga is read on that date.
    @Test func aCompletionWithADate() {
        let result = plan(
            ["c1": .init(completed: false, progress: 3, total: 10, dateRead: day(1))],
            ["c1": .init(completed: true, page: 0, date: day(2))]
        )
        #expect(result.steps == [.complete(chapterKey: "c1", date: day(2), journalDetail: "fecha \(day(2)), local pág 3/10")])
        #expect(result.mangaRead == day(2))
    }

    /// Completed on the tracker without a date and with no local history: completed «now», but the manga is not read
    /// recently because of it (lastRead stays at .distantPast: no setRead, SUWA-12 H4).
    @Test func aCompletionWithoutDateCompletesNowWithoutReadingTheManga() {
        let result = plan([:], ["c1": .init(completed: true, page: 0, date: nil)])
        #expect(result.steps == [.complete(chapterKey: "c1", date: now, journalDetail: "fecha ninguna, local sin historial")])
        #expect(result.mangaRead == nil)
    }

    /// Already completed here: nothing (not even with a newer date).
    @Test func alreadyCompletedHereTouchesNothing() {
        let result = plan(
            ["c1": .init(completed: true, progress: -1, total: 0, dateRead: day(1))],
            ["c1": .init(completed: true, page: 0, date: day(3))]
        )
        #expect(result == TrackerSyncPlan())
    }

    /// Not completed with a page: the page, not completed, with the tracker's date or «now»; the manga is read.
    @Test func aPage() {
        let dated = plan([:], ["c1": .init(completed: false, page: 5, date: day(2))])
        #expect(dated.steps == [.progress(chapterKey: "c1", page: 5, date: day(2))])
        #expect(dated.mangaRead == day(2))
        #expect(dated.progressed == ["c1": 5])
        let undated = plan([:], ["c1": .init(completed: false, page: 5, date: nil)])
        #expect(undated.steps == [.progress(chapterKey: "c1", page: 5, date: now)])
        #expect(undated.mangaRead == now)
    }

    /// Not completed and page 0: nothing.
    @Test func pageZeroTouchesNothing() {
        #expect(plan([:], ["c1": .init(completed: false, page: 0, date: day(2))]) == TrackerSyncPlan())
    }

    /// The manga's read date is the latest of what was written.
    @Test func theMangaIsReadOnTheLatestDate() {
        let result = plan(
            [:],
            [
                "c1": .init(completed: true, page: 0, date: day(3)),
                "c2": .init(completed: false, page: 2, date: day(5)),
                "c3": .init(completed: true, page: 0, date: day(1)),
            ]
        )
        #expect(Set(result.completed) == ["c1", "c3"])
        #expect(result.progressed == ["c2": 2])
        #expect(result.mangaRead == day(5))
    }
}
