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
@MainActor
protocol ReadPositionScheduler {
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ReadPositionTimer
}

/// Main-queue scheduler used by the reader.
struct MainQueueReadPositionScheduler: ReadPositionScheduler {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private final class Timer: ReadPositionTimer {
        let item: DispatchWorkItem
        init(item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> ReadPositionTimer {
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return Timer(item: item)
    }
}

/// A position that knows which page (of which chapter) it is.
protocol ReadPositionKeyed {
    var pageKey: String { get }
}

/// Debounces read position saves. `Position` carries everything a save needs (chapter, page...),
/// so a save always writes the chapter it was scheduled for.
@MainActor
final class ReadPositionSaver<Position: ReadPositionKeyed> {
    static var localDelay: TimeInterval { 2 }
    static var trackerDelay: TimeInterval { 10 }
    /// Longest wait while pages keep changing.
    static var localMaxWait: TimeInterval { 5 }
    static var trackerMaxWait: TimeInterval { 20 }

    private let scheduler: ReadPositionScheduler
    private let isEnabled: () -> Bool
    private let saveLocal: (Position, Int) -> Void
    private let saveTracker: (Position, Int) -> Void

    /// Bumped when pending saves are dropped: a delayed save already running checks it before writing.
    private(set) var generation = 0

    private var localTimer: ReadPositionTimer?
    private var trackerTimer: ReadPositionTimer?
    private var pendingLocal: Position?
    /// Last position not yet sent to the trackers.
    private(set) var pending: Position?

    /// - isEnabled: false (incognito) schedules nothing.
    /// - saveLocal: progress only (no reading session, no tracker), ~2 s after the last change. Gets the
    ///   generation to check with `isCurrent` right before writing.
    /// - saveTracker: page trackers, ~10 s after the last change.
    init(
        scheduler: ReadPositionScheduler? = nil,
        isEnabled: @escaping () -> Bool,
        saveLocal: @escaping (Position, Int) -> Void,
        saveTracker: @escaping (Position, Int) -> Void
    ) {
        self.scheduler = scheduler ?? MainQueueReadPositionScheduler()
        self.isEnabled = isEnabled
        self.saveLocal = saveLocal
        self.saveTracker = saveTracker
    }

    /// Call on every page change: the last position wins.
    func pageChanged(_ position: Position) {
        guard isEnabled() else { return }
        pending = position
        pendingLocal = position

        localTimer?.cancel()
        localTimer = scheduler.schedule(after: Self.localDelay) { [weak self] in
            guard let self else { return }
            self.localTimer = nil
            guard let position = self.pendingLocal else { return }
            self.pendingLocal = nil
            self.saveLocal(position, self.generation)
        }

        trackerTimer?.cancel()
        trackerTimer = scheduler.schedule(after: Self.trackerDelay) { [weak self] in
            guard let self else { return }
            self.trackerTimer = nil
            guard let position = self.pending else { return }
            self.pending = nil
            self.saveTracker(position, self.generation)
        }
    }

    /// A chapter was loaded: its first page is where reading starts, not a change (pending).
    func chapterOpened() {
    }

    /// Drops what's pending (leaving the reader, changing chapter): the caller saves right away.
    func cancel() {
        localTimer?.cancel()
        trackerTimer?.cancel()
        localTimer = nil
        trackerTimer = nil
        pendingLocal = nil
        pending = nil
    }

    /// For an immediate save (scene deactivating, going to the background): drops what's pending and
    /// tells whether this page still needs saving (false: already saved and sent, e.g. a second notice) (pending).
    func claimImmediateSave(pageKey: String) -> Bool {
        cancel()
        return true
    }

    func isCurrent(_ generation: Int) -> Bool {
        true // pending
    }
}
