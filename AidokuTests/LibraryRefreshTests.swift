//
//  LibraryRefreshTests.swift
//  AidokuTests
//
//  The library refresh after history changes: grouped, and not while the library can't be seen.
//

import Foundation
import Testing

@testable import Aidoku

@MainActor
private final class Clock: ReadPositionScheduler {
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
        while let next = items.filter({ !$0.timer.cancelled && $0.fire <= end + 0.000_001 }).min(by: { ($0.fire, $0.order) < ($1.fire, $1.order) }) {
            items.removeAll { $0.timer === next.timer }
            now = max(now, next.fire)
            next.action()
        }
        now = end
    }
}

@MainActor
private final class Library {
    let clock = Clock()
    var visibility = CoalescedRefresh<String>.Visibility.visible
    var refreshes: [[String]] = []
    lazy var refresher = CoalescedRefresh<String>(
        scheduler: clock,
        visibility: { [unowned self] in self.visibility },
        refresh: { [unowned self] in self.refreshes.append($0) }
    )
}

@MainActor
struct LibraryRefreshTests {
    @Test func noticesInARowGiveOneRefresh() {
        let l = Library()
        for i in 0..<10 {
            l.refresher.signal(i.isMultiple(of: 2) ? "a" : "b")
            l.clock.advance(by: 0.1)
        }
        #expect(l.refreshes.isEmpty)
        l.clock.advance(by: 1.1)
        #expect(l.refreshes == [["a", "b"]]) // each once, the latest last
    }

    /// 60 s reading with the reader over the library, the page saved every 2 s (SUWA-7).
    @Test func readingOverTheLibraryRefreshesOnceWhenItCloses() {
        let l = Library()
        l.visibility = .covered
        for _ in 0..<30 {
            l.refresher.signal("manga")
            l.clock.advance(by: 2)
        }
        #expect(l.refreshes.isEmpty) // before: 30 refreshes (one full reload each with «unread» filter)
        l.visibility = .visible // the reader closed
        l.clock.advance(by: 2)
        #expect(l.refreshes == [["manga"]])
    }

    @Test func hiddenLibraryRefreshesWhenItAppears() {
        let l = Library()
        l.visibility = .hidden
        l.refresher.signal("a")
        l.clock.advance(by: 30)
        l.refresher.signal("b")
        l.clock.advance(by: 30)
        #expect(l.refreshes.isEmpty)
        l.visibility = .visible
        l.refresher.appeared()
        #expect(l.refreshes == [["a", "b"]])
        l.refresher.appeared() // nothing new
        l.clock.advance(by: 30)
        #expect(l.refreshes.count == 1)
    }

    @Test func theLibrarysStateGivesItsVisibility() {
        typealias R = CoalescedRefresh<String>
        #expect(R.visibility(isViewLoaded: false, isInWindow: false, isPresentingSomething: false) == .hidden)
        #expect(R.visibility(isViewLoaded: true, isInWindow: false, isPresentingSomething: false) == .hidden) // another tab
        #expect(R.visibility(isViewLoaded: true, isInWindow: false, isPresentingSomething: true) == .hidden)
        #expect(R.visibility(isViewLoaded: true, isInWindow: true, isPresentingSomething: true) == .covered) // the reader
        #expect(R.visibility(isViewLoaded: true, isInWindow: true, isPresentingSomething: false) == .visible)
    }
}
