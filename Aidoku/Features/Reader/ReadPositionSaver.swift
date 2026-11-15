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

enum ReadPositionKey {
    /// Chapter + page, plus the scroll position (rounded to 1 %) when the reader reports one (text reader),
    /// so moving within one virtual page is a change too.
    static func make(chapterKey: String, page: Int, position: Double?) -> String {
        guard let position else { return "\(chapterKey)#\(page)" }
        return "\(chapterKey)#\(page)@" + String(format: "%.2f", position)
    }
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
    /// When the oldest unsaved change happened (for the maximum waits).
    private var localSince: TimeInterval?
    private var trackerSince: TimeInterval?
    /// Last page saved locally / sent (also the opening page, which is already stored).
    private var lastLocalKey: String?
    private var lastTrackerKey: String?

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
        let key = position.pageKey
        // back on (or still on) the page already saved and sent, e.g. where the chapter opened: nothing to do
        if key == lastLocalKey && key == lastTrackerKey {
            dropPending()
            return
        }
        pending = position
        pendingLocal = position
        let now = scheduler.now

        localTimer?.cancel()
        let localStart = localSince ?? now
        localSince = localStart
        let localDelay = min(Self.localDelay, max(0, Self.localMaxWait - (now - localStart)))
        localTimer = scheduler.schedule(after: localDelay) { [weak self] in
            guard let self else { return }
            self.localTimer = nil
            self.localSince = nil
            guard let position = self.pendingLocal else { return }
            self.pendingLocal = nil
            guard position.pageKey != self.lastLocalKey else { return } // already saved
            self.lastLocalKey = position.pageKey
            self.saveLocal(position, self.generation)
        }

        trackerTimer?.cancel()
        let trackerStart = trackerSince ?? now
        trackerSince = trackerStart
        let trackerDelay = min(Self.trackerDelay, max(0, Self.trackerMaxWait - (now - trackerStart)))
        trackerTimer = scheduler.schedule(after: trackerDelay) { [weak self] in
            guard let self else { return }
            self.trackerTimer = nil
            self.trackerSince = nil
            guard let position = self.pending else { return }
            self.pending = nil
            guard position.pageKey != self.lastTrackerKey else { return } // already sent
            self.lastTrackerKey = position.pageKey
            self.saveTracker(position, self.generation)
        }
    }

    /// A chapter was loaded at `pageKey` (the stored position it starts at): reports of that page are
    /// not a change, whenever (or whether) the reader reports it.
    func chapterOpened(pageKey: String) {
        cancel()
        lastLocalKey = pageKey
        lastTrackerKey = pageKey
    }

    /// A delayed save of `pageKey` was dropped (old generation) without writing: it's not saved.
    func discarded(pageKey: String) {
        if lastLocalKey == pageKey {
            lastLocalKey = nil
        }
        if lastTrackerKey == pageKey {
            lastTrackerKey = nil
        }
    }

    /// Drops what's pending (leaving the reader, changing chapter): the caller saves right away. Saves
    /// already running are dropped too (new generation).
    func cancel() {
        dropPending()
        generation += 1
    }

    /// Cancels the timers and what they would save; saves already running go on.
    private func dropPending() {
        localTimer?.cancel()
        trackerTimer?.cancel()
        localTimer = nil
        trackerTimer = nil
        pendingLocal = nil
        pending = nil
        localSince = nil
        trackerSince = nil
    }

    /// For an immediate save (scene deactivating, going to the background): drops what's pending and
    /// tells whether this page still needs saving (false: already saved and sent, e.g. a second notice).
    func claimImmediateSave(pageKey: String) -> Bool {
        if pageKey == lastLocalKey && pageKey == lastTrackerKey {
            // saved and sent (or being written by saves already running, which write this same page)
            dropPending()
            return false
        }
        cancel()
        lastLocalKey = pageKey
        lastTrackerKey = pageKey
        return true
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }
}
