//
//  TrackerSyncPlanner.swift
//  Aidoku
//
//  SUWA-13 F4 L11b (D-L11-6): what the page trackers' history does to the local one, decided without the store.
//  The rules are the ones TrackerManager.syncPageTrackerHistory applied inside its context.
//

import Foundation

enum TrackerSyncPlanner {
    /// - local: the local history of the chapters that have one (chapter key → history).
    /// - remote: the trackers' progress (chapter key → progress).
    /// - now: the date of what comes without one.
    static func plan(local: [String: TrackerSyncLocal], remote: [String: ChapterReadProgress], now: Date = Date()) -> TrackerSyncPlan {
        TrackerSyncPlan() // L11b andamiaje: the rules are still in TrackerManager
    }
}
