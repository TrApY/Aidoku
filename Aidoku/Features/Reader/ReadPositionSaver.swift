//
//  ReadPositionSaver.swift
//  Aidoku
//
//  Saves the reading position while reading, not only when leaving the reader: a local save a short
//  time after the last page change and a page tracker update after a longer one, both debounced.
//  If the app is killed (installing a build, force quit, memory), at most the last ~2 s are lost.
//

import Foundation

/// A pending delayed action that can be cancelled.
protocol ReadPositionTimer {
    func cancel()
}

/// Runs an action after a delay. Injectable so tests can drive the clock.
protocol ReadPositionScheduler {
    @MainActor
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ReadPositionTimer
}

/// Main-queue scheduler used by the reader.
struct MainQueueReadPositionScheduler: ReadPositionScheduler {
    private final class Timer: ReadPositionTimer {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ReadPositionTimer {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Timer(item: item)
    }
}

/// Debounces read position saves. `Position` carries everything a save needs (chapter, page...),
/// so a save always writes the chapter it was scheduled for.
@MainActor
final class ReadPositionSaver<Position> {
    static var localDelay: TimeInterval { 2 }
    static var trackerDelay: TimeInterval { 10 }

    private let scheduler: ReadPositionScheduler
    private let isEnabled: () -> Bool
    private let saveLocal: (Position) -> Void
    private let saveTracker: (Position) -> Void

    private var localTimer: ReadPositionTimer?
    private var trackerTimer: ReadPositionTimer?
    private(set) var pending: Position?

    /// - isEnabled: false (incognito) schedules nothing.
    /// - saveLocal: progress only (no reading session, no tracker), ~2 s after the last change.
    /// - saveTracker: page trackers, ~10 s after the last change.
    init(
        scheduler: ReadPositionScheduler = MainQueueReadPositionScheduler(),
        isEnabled: @escaping () -> Bool,
        saveLocal: @escaping (Position) -> Void,
        saveTracker: @escaping (Position) -> Void
    ) {
        self.scheduler = scheduler
        self.isEnabled = isEnabled
        self.saveLocal = saveLocal
        self.saveTracker = saveTracker
    }

    /// Call on every page change: the last position wins.
    func pageChanged(_ position: Position) {
        // pending
    }

    /// Drops what's pending (leaving the reader, changing chapter): the caller saves right away.
    func cancel() {
        // pending
    }

    /// Cancels the delayed saves and returns the pending position (the caller saves it now).
    @discardableResult
    func flush() -> Position? {
        nil // pending
    }
}
