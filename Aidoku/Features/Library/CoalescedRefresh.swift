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

    /// Something changed (pending: refreshes right away, as before).
    func signal(_ key: Key) {
        refresh([key])
    }

    /// The screen appeared again (pending).
    func appeared() {
    }
}
