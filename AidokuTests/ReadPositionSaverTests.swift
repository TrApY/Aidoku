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

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let next = items.filter({ !$0.timer.cancelled && $0.fire <= end }).min(by: { ($0.fire, $0.order) < ($1.fire, $1.order) }) {
            items.removeAll { $0.timer === next.timer }
            now = next.fire
            next.action()
        }
        now = end
    }
}

private struct Position: Equatable {
    let chapter: String
    let page: Int
}

@MainActor
private final class Harness {
    let scheduler = FakeScheduler()
    var enabled = true
    var local: [(Position, TimeInterval)] = []
    var tracker: [(Position, TimeInterval)] = []
    lazy var saver = ReadPositionSaver<Position>(
        scheduler: scheduler,
        isEnabled: { [unowned self] in self.enabled },
        saveLocal: { [unowned self] in self.local.append(($0, self.scheduler.now)) },
        saveTracker: { [unowned self] in self.tracker.append(($0, self.scheduler.now)) }
    )
}

@MainActor
struct ReadPositionSaverTests {
    @Test func changesInARowGiveOneSaveOfTheLastPage() {
        let h = Harness()
        for page in 1...5 {
            h.saver.pageChanged(.init(chapter: "c1", page: page))
            h.scheduler.advance(by: 0.2) // 5 changes in 1 s
        }
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.0) == [.init(chapter: "c1", page: 5)])
        #expect(h.tracker.map(\.0) == [.init(chapter: "c1", page: 5)])
    }

    @Test func localSaveTwoSecondsAfterTheLastChange() {
        let h = Harness()
        h.saver.pageChanged(.init(chapter: "c1", page: 3))
        h.scheduler.advance(by: 1.9)
        #expect(h.local.isEmpty)
        h.scheduler.advance(by: 0.2)
        #expect(h.local.count == 1)
        #expect(abs((h.local.first?.1 ?? 0) - 2) < 0.001)
        #expect(h.tracker.isEmpty) // the tracker waits longer
        #expect(h.saver.pending == .init(chapter: "c1", page: 3)) // still pending for the tracker
    }

    @Test func trackerTenSecondsAfterTheLastChange() {
        let h = Harness()
        h.saver.pageChanged(.init(chapter: "c1", page: 3))
        h.scheduler.advance(by: 6)
        h.saver.pageChanged(.init(chapter: "c1", page: 4)) // restarts both delays
        h.scheduler.advance(by: 9.9)
        #expect(h.tracker.isEmpty)
        h.scheduler.advance(by: 0.2)
        #expect(h.tracker.map(\.0) == [.init(chapter: "c1", page: 4)])
        #expect(abs((h.tracker.first?.1 ?? 0) - 16) < 0.001)
        // the local save ran for each burst (page 3 at 2 s, page 4 at 8 s)
        #expect(h.local.map(\.0.page) == [3, 4])
        #expect(h.saver.pending == nil)
    }

    @Test func changingChapterCancelsWhatIsPending() {
        let h = Harness()
        h.saver.pageChanged(.init(chapter: "c1", page: 7))
        h.scheduler.advance(by: 1)
        h.saver.cancel() // leaving the reader / new chapter: the reader saves c1 right away itself
        h.saver.pageChanged(.init(chapter: "c2", page: 2))
        h.scheduler.advance(by: 30)
        #expect(h.local.map(\.0) == [.init(chapter: "c2", page: 2)])
        #expect(h.tracker.map(\.0) == [.init(chapter: "c2", page: 2)])
        h.saver.pageChanged(.init(chapter: "c2", page: 3))
        h.saver.cancel()
        h.scheduler.advance(by: 30)
        #expect(h.local.count == 1)
        #expect(h.saver.pending == nil)
    }

    @Test func deactivationFlushesRightAway() {
        let h = Harness()
        h.saver.pageChanged(.init(chapter: "c1", page: 8))
        h.scheduler.advance(by: 0.5)
        h.saver.pageChanged(.init(chapter: "c1", page: 9))
        let flushed = h.saver.flush()
        #expect(flushed == .init(chapter: "c1", page: 9))
        h.scheduler.advance(by: 30)
        // the delayed saves are gone: the reader saved (local + tracker) at once
        #expect(h.local.isEmpty)
        #expect(h.tracker.isEmpty)
        #expect(h.saver.flush() == nil)
    }

    @Test func incognitoSavesNothing() {
        let h = Harness()
        h.enabled = false
        h.saver.pageChanged(.init(chapter: "c1", page: 4))
        h.scheduler.advance(by: 30)
        #expect(h.local.isEmpty)
        #expect(h.tracker.isEmpty)
        #expect(h.saver.flush() == nil)
    }
}
