//
//  ReadPositionSaver.swift
//  Aidoku
//
//  Saves the reading position while reading, not only when leaving the reader: a local save a short
//  time after the last page change (at most every 5 s) and a page tracker update after a longer one
//  (30 s, at most every 60 s), both debounced. If the app is killed (installing a build, force quit,
//  memory), at most the last ~2-5 s are lost locally.
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
    /// What the page trackers get: the page, without the scroll position.
    var trackerKey: String { get }
}

enum ReadPositionKey {
    /// Chapter + page, plus the scroll position (rounded to 1 %) when the reader reports one (text reader),
    /// so moving within one virtual page is a change too.
    static func make(chapterKey: String, page: Int, position: Double?) -> String {
        guard let position else { return "\(chapterKey)#\(page)" }
        return "\(chapterKey)#\(page)@" + String(format: "%.2f", position)
    }

    /// Where a chapter opens, as its reader will report it: the start page (the first one when there's no
    /// history or it's completed) and, for text readers, the stored scroll position (0 at the start).
    static func opening(chapterKey: String, startPage: Int, isTextReader: Bool, storedPosition: Double?) -> String {
        make(chapterKey: chapterKey, page: max(1, startPage), position: isTextReader ? (storedPosition ?? 0) : nil)
    }
}

/// Debounces read position saves. `Position` carries everything a save needs (chapter, page...),
/// so a save always writes the chapter it was scheduled for.
@MainActor
final class ReadPositionSaver<Position: ReadPositionKeyed> {
    static var localDelay: TimeInterval { 2 }
    static var trackerDelay: TimeInterval { 30 }
    /// Longest wait while pages keep changing.
    static var localMaxWait: TimeInterval { 5 }
    static var trackerMaxWait: TimeInterval { 60 }

    private let scheduler: ReadPositionScheduler
    private let isEnabled: () -> Bool
    private let saveLocal: (Position, Int) -> Void
    private let saveTracker: (Position, Int) -> Void

    /// Each delayed save gets its own number; only the latest one of each kind may write (`isCurrent`).
    private var lastSaveNumber = 0
    private var currentLocal: Int?
    private var currentTracker: Int?

    private var localTimer: ReadPositionTimer?
    private var trackerTimer: ReadPositionTimer?
    private var pendingLocal: Position?
    /// Last position not yet sent to the trackers.
    private(set) var pending: Position?
    /// When the oldest unsaved change happened (for the maximum waits).
    private var localSince: TimeInterval?
    private var trackerSince: TimeInterval?
    /// Last page saved locally / sent (also the opening page, which is already stored), and the delayed
    /// save that did it (nil: the opening page or an immediate save).
    private var lastLocalKey: String?
    private var lastTrackerKey: String?
    private var lastLocalSave: Int?
    private var lastTrackerSave: Int?

    /// - isEnabled: false (incognito) schedules nothing.
    /// - saveLocal: progress only (no reading session, no tracker), ~2 s after the last change. Gets the
    ///   number to check with `isCurrent` right before writing.
    /// - saveTracker: page trackers, ~30 s after the last change.
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
        let now = scheduler.now

        // back on (or still on) what's already saved, e.g. where the chapter opened: nothing to do for it
        if position.pageKey == lastLocalKey {
            dropPendingLocal()
        } else {
            pendingLocal = position
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
                let number = self.nextSaveNumber()
                self.currentLocal = number
                self.lastLocalKey = position.pageKey
                self.lastLocalSave = number
                self.saveLocal(position, number)
            }
        }

        // the trackers get the page: moving within it (text) is nothing to send
        if position.trackerKey == lastTrackerKey {
            dropPendingTracker()
        } else {
            pending = position
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
                guard position.trackerKey != self.lastTrackerKey else { return } // already sent
                let number = self.nextSaveNumber()
                self.currentTracker = number
                self.lastTrackerKey = position.trackerKey
                self.lastTrackerSave = number
                self.saveTracker(position, number)
            }
        }
    }

    /// A chapter was loaded at `pageKey` (the stored position it starts at): reports of that page are
    /// not a change, whenever (or whether) the reader reports it.
    func chapterOpened(pageKey: String, trackerKey: String? = nil) {
        cancel()
        lastLocalKey = pageKey
        lastTrackerKey = trackerKey ?? Self.trackerKey(of: pageKey)
        lastLocalSave = nil
        lastTrackerSave = nil
    }

    /// The delayed save number `generation` of `pageKey` was dropped without writing: it's not saved.
    /// Only that save's mark is cleared (a later save of the same page still counts).
    func discarded(pageKey: String, generation: Int) {
        if lastLocalSave == generation && lastLocalKey == pageKey {
            lastLocalKey = nil
            lastLocalSave = nil
        }
        if lastTrackerSave == generation && (lastTrackerKey == pageKey || lastTrackerKey == Self.trackerKey(of: pageKey)) {
            lastTrackerKey = nil
            lastTrackerSave = nil
        }
    }

    /// Drops what's pending (leaving the reader, changing chapter): the caller saves right away. Saves
    /// already running are dropped too.
    func cancel() {
        dropPending()
        currentLocal = nil
        currentTracker = nil
    }

    /// Cancels the timers and what they would save; saves already running go on.
    private func dropPending() {
        dropPendingLocal()
        dropPendingTracker()
    }

    private func dropPendingLocal() {
        localTimer?.cancel()
        localTimer = nil
        pendingLocal = nil
        localSince = nil
    }

    private func dropPendingTracker() {
        trackerTimer?.cancel()
        trackerTimer = nil
        pending = nil
        trackerSince = nil
    }

    private func nextSaveNumber() -> Int {
        lastSaveNumber += 1
        return lastSaveNumber
    }

    /// For an immediate save (scene deactivating, going to the background): drops what's pending and
    /// tells whether this page still needs saving (false: already saved and sent, e.g. a second notice).
    /// Only the latest delayed saves (which write this same page) may still write; older ones can't.
    func claimImmediateSave(pageKey: String, trackerKey: String? = nil) -> Bool {
        let trackerKey = trackerKey ?? Self.trackerKey(of: pageKey)
        if pageKey == lastLocalKey && trackerKey == lastTrackerKey {
            dropPending()
            return false
        }
        cancel()
        lastLocalKey = pageKey
        lastTrackerKey = trackerKey
        lastLocalSave = nil
        lastTrackerSave = nil
        return true
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == currentLocal || generation == currentTracker
    }

    /// The page key without the scroll position («c#5@0.42» → «c#5»). Only a «#<page>@<number>» end is
    /// a position: a chapter key may contain «@» itself.
    static func trackerKey(of pageKey: String) -> String {
        guard
            let range = pageKey.range(of: #"#[0-9]+@-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression),
            let at = pageKey[range].firstIndex(of: "@")
        else {
            return pageKey
        }
        return String(pageKey[..<at])
    }
}

/// Which page changes a reader reports: only real changes, and always the first page of a newly
/// loaded chapter, even if it has the number the previous one had.
struct PageReportFilter {
    private var previousPage = 0

    mutating func shouldReport(_ page: Int) -> Bool {
        guard page != previousPage else { return false }
        previousPage = page
        return true
    }

    /// A new chapter: its first page is reported.
    mutating func reset() {
        previousPage = 0
    }
}
