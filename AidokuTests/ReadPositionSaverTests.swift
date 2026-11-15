//
//  ReadPositionSaverTests.swift
//  AidokuTests
//

import Foundation
import Testing

@testable import Aidoku

/// A clock the test moves by hand.
@MainActor
private final class FakeScheduler: ReadPositionScheduler {
    private final class Timer: ReadPositionTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private var items: [(fire: TimeInterval, order: Int, timer: Timer, action: @MainActor @Sendable () -> Void)] = []
    private var order = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ReadPositionTimer {
        let timer = Timer()
        order += 1
        items.append((now + delay, order, timer, action))
        return timer
    }

    var pendingCount: Int { items.filter { !$0.timer.cancelled }.count }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = items.filter({ !$0.timer.cancelled && $0.fire <= end + 0.000_001 }).min(by: { ($0.fire, $0.order) < ($1.fire, $1.order) }) {
            items.removeAll { $0.timer === next.timer }
            now = max(now, next.fire)
            next.action()
        }
        now = end
    }
}

private struct Position: Equatable, ReadPositionKeyed {
    let chapter: String
    let page: Int
    var pageKey: String { "\(chapter)#\(page)" }
}

@MainActor
private final class Harness {
    let scheduler = FakeScheduler()
    var enabled = true
    var local: [(position: Position, at: TimeInterval, generation: Int)] = []
    var tracker: [(position: Position, at: TimeInterval, generation: Int)] = []
    lazy var saver = ReadPositionSaver<Position>(
        scheduler: scheduler,
        isEnabled: { [unowned self] in self.enabled },
        saveLocal: { [unowned self] in self.local.append(($0, self.scheduler.now, $1)) },
        saveTracker: { [unowned self] in self.tracker.append(($0, self.scheduler.now, $1)) }
    )

    func turn(_ page: Int, chapter: String = "c1") {
        saver.pageChanged(.init(chapter: chapter, page: page))
    }
}

@MainActor
struct ReadPositionSaverTests {
    @Test func changesInARowGiveOneSaveOfTheLastPage() {
        let h = Harness()
        for page in 1...5 {
            h.turn(page)
            h.scheduler.advance(by: 0.2) // 5 changes in 1 s
        }
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position) == [.init(chapter: "c1", page: 5)])
        #expect(h.tracker.map(\.position) == [.init(chapter: "c1", page: 5)])
    }

    @Test func localSaveTwoSecondsAfterTheLastChange() {
        let h = Harness()
        h.turn(3)
        h.scheduler.advance(by: 1.9)
        #expect(h.local.isEmpty)
        h.scheduler.advance(by: 0.2)
        #expect(h.local.count == 1)
        #expect(abs((h.local.first?.at ?? 0) - 2) < 0.001)
        #expect(h.tracker.isEmpty) // the tracker waits longer
    }

    @Test func trackerTenSecondsAfterTheLastChange() {
        let h = Harness()
        h.turn(3)
        h.scheduler.advance(by: 6)
        h.turn(4) // restarts both delays
        h.scheduler.advance(by: 9.9)
        #expect(h.tracker.isEmpty)
        h.scheduler.advance(by: 0.2)
        #expect(h.tracker.map(\.position) == [.init(chapter: "c1", page: 4)])
        #expect(abs((h.tracker.first?.at ?? 0) - 16) < 0.001)
        #expect(h.local.map(\.position.page) == [3, 4])
    }

    @Test func readingNonStopStillSaves() {
        let h = Harness()
        // a page every second for 40 s: the delays never run out, the maximum waits do
        for page in 1...40 {
            h.turn(page)
            h.scheduler.advance(by: 1)
        }
        #expect(h.local.count >= 7)
        let localTimes = [0] + h.local.map(\.at)
        #expect(zip(localTimes, localTimes.dropFirst()).allSatisfy { $1 - $0 <= 5.001 })
        #expect(h.tracker.count >= 2)
        let trackerTimes = [0] + h.tracker.map(\.at)
        #expect(zip(trackerTimes, trackerTimes.dropFirst()).allSatisfy { $1 - $0 <= 20.001 })
        // what's saved is the page shown at that moment
        #expect(h.local.allSatisfy { Double($0.position.page) >= $0.at - 1 })
    }

    @Test func theOpeningPageIsNotSaved() {
        let h = Harness()
        h.saver.chapterOpened(pageKey: "c1#5") // the stored page loadCurrentChapter starts at
        h.turn(5) // the reader reports where it opened
        h.scheduler.advance(by: 30)
        h.turn(5) // same page again (scrolling within it)
        h.scheduler.advance(by: 30)
        #expect(h.local.isEmpty)
        #expect(h.tracker.isEmpty)
        // nothing to save when leaving the app either
        #expect(!h.saver.claimImmediateSave(pageKey: "c1#5"))
        // the first real change is saved
        h.turn(6)
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position.page) == [6])
        #expect(h.tracker.map(\.position.page) == [6])
    }

    @Test func aReaderThatDoesNotReportTheOpeningPage() {
        // webtoon opening at the page number the last chapter had: it reports nothing until the user moves
        let h = Harness()
        h.saver.chapterOpened(pageKey: "c2#5")
        h.turn(6, chapter: "c2") // the user's first change
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position) == [.init(chapter: "c2", page: 6)])
        #expect(h.tracker.map(\.position) == [.init(chapter: "c2", page: 6)])
    }

    @Test func aReaderThatSettlesBackOnTheOpeningPage() {
        // webtoon re-centering while images load (4, then 5) or text paging (provisional, then the real one)
        let h = Harness()
        h.saver.chapterOpened(pageKey: "c1#5")
        h.turn(4)
        h.scheduler.advance(by: 0.5)
        h.turn(5)
        h.scheduler.advance(by: 30)
        #expect(h.local.isEmpty)
        #expect(h.tracker.isEmpty)
    }

    @Test func backToAPageAfterAnotherWasSaved() {
        let h = Harness()
        h.saver.chapterOpened(pageKey: "c1#5")
        h.turn(6)
        h.scheduler.advance(by: 30) // 6 saved and sent
        h.turn(5)
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position.page) == [6, 5])
        #expect(h.tracker.map(\.position.page) == [6, 5])
    }

    @Test func theSamePageAgainSchedulesNothing() {
        let h = Harness()
        h.turn(6)
        h.scheduler.advance(by: 30) // saved and sent
        h.turn(6) // reported again (not the opening page)
        #expect(h.scheduler.pendingCount == 0)
        // and back to it before another page is saved: the pending saves are dropped
        h.turn(7)
        h.scheduler.advance(by: 0.5)
        h.turn(6)
        #expect(h.scheduler.pendingCount == 0)
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position.page) == [6])
    }

    @Test func backgroundWithLocalSavedButNotSent() {
        let h = Harness()
        h.turn(6)
        h.scheduler.advance(by: 3) // saved locally, not sent yet
        #expect(h.local.count == 1)
        #expect(h.tracker.isEmpty)
        #expect(h.saver.claimImmediateSave(pageKey: "c1#6")) // still needs sending
        #expect(!h.saver.claimImmediateSave(pageKey: "c1#6"))
    }

    @Test func aDiscardedSaveIsNotCountedAsSaved() {
        let h = Harness()
        h.turn(6)
        h.scheduler.advance(by: 11) // local and tracker saves fired (running, async)
        let local = h.local.first?.generation ?? -1
        // the same page saved right away (deactivate): nothing to discard, the running saves write it
        #expect(!h.saver.claimImmediateSave(pageKey: "c1#6"))
        #expect(h.saver.isCurrent(local))
        // something else dropped them (e.g. leaving the reader) before they wrote
        h.saver.cancel()
        #expect(!h.saver.isCurrent(local))
        h.saver.discarded(pageKey: "c1#6")
        // the background notice then must save it
        #expect(h.saver.claimImmediateSave(pageKey: "c1#6"))
    }

    @Test func pageKeyIncludesTheScrollPosition() {
        #expect(ReadPositionKey.make(chapterKey: "c1", page: 5, position: nil) == "c1#5")
        let a = ReadPositionKey.make(chapterKey: "c1", page: 5, position: 0.421)
        let b = ReadPositionKey.make(chapterKey: "c1", page: 5, position: 0.459)
        #expect(a != b) // moving within one virtual page of the text reader is a change
        #expect(a == ReadPositionKey.make(chapterKey: "c1", page: 5, position: 0.4204)) // rounded (1 %)
        #expect(a != "c1#5")
    }

    @Test func thePageLastSavedIsNotSavedAgain() {
        let h = Harness()
        h.turn(3)
        h.scheduler.advance(by: 3) // c1#3 saved
        h.turn(4)
        h.scheduler.advance(by: 0.5)
        h.turn(3) // back before the save of 4
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position.page) == [3])
        #expect(h.tracker.map(\.position.page) == [3])
    }

    @Test func changingChapterCancelsWhatIsPending() {
        let h = Harness()
        h.turn(7)
        h.scheduler.advance(by: 1)
        h.saver.cancel() // leaving the reader / new chapter: the reader saves c1 right away itself
        h.turn(2, chapter: "c2")
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.position) == [.init(chapter: "c2", page: 2)])
        #expect(h.tracker.map(\.position) == [.init(chapter: "c2", page: 2)])
        h.turn(3, chapter: "c2")
        h.saver.cancel()
        h.scheduler.advance(by: 30)
        #expect(h.local.count == 1)
        #expect(h.saver.pending == nil)
    }

    @Test func deactivationSavesRightAwayAndOnlyOnce() {
        let h = Harness()
        h.turn(8)
        h.scheduler.advance(by: 0.5)
        h.turn(9)
        // will deactivate: save now
        #expect(h.saver.claimImmediateSave(pageKey: "c1#9"))
        // did enter background right after: same page, already saved
        #expect(!h.saver.claimImmediateSave(pageKey: "c1#9"))
        h.scheduler.advance(by: 30)
        #expect(h.local.isEmpty) // the delayed saves are gone
        #expect(h.tracker.isEmpty)
        // a page later, it saves again
        h.turn(10)
        #expect(h.saver.claimImmediateSave(pageKey: "c1#10"))
    }

    @Test func anOldDelayedSaveIsDiscarded() {
        let h = Harness()
        h.turn(3)
        h.scheduler.advance(by: 2.1)
        let started = try? #require(h.local.first?.generation)
        #expect(h.saver.isCurrent(started ?? -1))
        // the save is still running (async) when the position is saved right away
        _ = h.saver.claimImmediateSave(pageKey: "c1#4")
        #expect(!h.saver.isCurrent(started ?? -1))
        // later delayed saves carry the new generation
        h.turn(5)
        h.scheduler.advance(by: 3)
        let later = h.local.last?.generation ?? -1
        #expect(h.saver.isCurrent(later))
    }

    @Test func incognitoSavesNothing() {
        let h = Harness()
        h.enabled = false
        h.turn(4)
        h.scheduler.advance(by: 30)
        #expect(h.local.isEmpty)
        #expect(h.tracker.isEmpty)
        #expect(h.saver.pending == nil)
    }
}
