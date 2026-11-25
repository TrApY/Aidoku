//
//  TrackerSyncValues.swift
//  Aidoku
//
//  SUWA-13 F4 L11b: the page trackers' history brought to the local one (D-L11-6). TrackerSyncPlanner decides
//  from these values, without the store; HistoryRepository.applyTrackerSync reads, plans and writes in one context.
//

import Foundation

/// What the local history has of a chapter.
struct TrackerSyncLocal: Sendable, Equatable {
    var completed: Bool
    var progress: Int
    var total: Int
    var dateRead: Date?
}

/// What to write, in the order of the tracker's chapters.
struct TrackerSyncPlan: Sendable, Equatable {
    enum Step: Sendable, Equatable {
        /// Complete the chapter with this read date; `journalDetail` goes with its journal line.
        case complete(chapterKey: String, date: Date, journalDetail: String)
        /// Its page, not completed, with this read date.
        case progress(chapterKey: String, page: Int, date: Date)
    }

    var steps: [Step] = []
    /// The manga's last read date, if it has to be set.
    var mangaRead: Date?

    /// The chapters completed, in order.
    var completed: [String] {
        steps.compactMap { if case let .complete(key, _, _) = $0 { key } else { nil } }
    }

    /// chapter key → page, of the chapters given a page.
    var progressed: [String: Int] {
        var pages: [String: Int] = [:]
        for case let .progress(key, page, _) in steps {
            pages[key] = page
        }
        return pages
    }
}

/// What applying a plan did.
struct TrackerSyncResult: Sendable, Equatable {
    /// Whether the save went well.
    var saved: Bool
    /// What was planned (and written, if saved).
    var plan: TrackerSyncPlan

    var completed: [String] { plan.completed }
    var progressed: [String: Int] { plan.progressed }
}
