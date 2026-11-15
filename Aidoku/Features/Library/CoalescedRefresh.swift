//
//  CoalescedRefresh.swift
//  Aidoku
//
//  Groups frequent change notices (the reader saves the page every few seconds) into one refresh
//  a short time after the last one, and only while the screen can be seen: hidden, it just keeps
//  what changed and refreshes when it appears again.
//

import Foundation

@MainActor
final class CoalescedRefresh<Key: Hashable> {
    enum Visibility {
        /// On screen.
        case visible
        /// In the window but covered (something presented over it, like the reader).
        case covered
        /// Not in the window (another tab, another screen pushed on top).
        case hidden
    }

    static var delay: TimeInterval { 1 }

    /// A screen's visibility from its view controller state (pending: always visible).
    static func visibility(isViewLoaded: Bool, isInWindow: Bool, isPresentingSomething: Bool) -> Visibility {
        .visible
    }

    private let scheduler: ReadPositionScheduler
    private let visibility: () -> Visibility
    private let refresh: ([Key]) -> Void

    /// What changed since the last refresh, oldest first (each key once, at its latest position).
    private(set) var pendingKeys: [Key] = []
    private var timer: ReadPositionTimer?

    init(
        scheduler: ReadPositionScheduler? = nil,
        visibility: @escaping () -> Visibility,
        refresh: @escaping ([Key]) -> Void
    ) {
        self.scheduler = scheduler ?? MainQueueReadPositionScheduler()
        self.visibility = visibility
        self.refresh = refresh
    }

    /// Something changed: refresh a second after the last notice, if it can be seen by then.
    func signal(_ key: Key) {
        pendingKeys.removeAll { $0 == key }
        pendingKeys.append(key)
        guard visibility() != .hidden else {
            // nothing to do until it appears again
            timer?.cancel()
            timer = nil
            return
        }
        schedule()
    }

    /// The screen appeared again: refresh what changed meanwhile.
    func appeared() {
        timer?.cancel()
        timer = nil
        fire()
    }

    private func schedule() {
        timer?.cancel()
        timer = scheduler.schedule(after: Self.delay) { [weak self] in
            self?.timer = nil
            self?.fire()
        }
    }

    private func fire() {
        guard !pendingKeys.isEmpty else { return }
        switch visibility() {
            case .visible:
                let keys = pendingKeys
                pendingKeys = []
                refresh(keys)
            case .covered:
                // the reader is over it: look again later (no work until then)
                schedule()
            case .hidden:
                break // refreshed on `appeared`
        }
    }
}
