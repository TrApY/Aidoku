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
        var plan = TrackerSyncPlan()
        var lastRead = Date.distantPast

        for (chapterKey, progress) in remote {
            let existingHistory = local[chapterKey]
            // without a date from the tracker the local history can't be compared: it stays (SUWA-12 F);
            // a chapter with no local history still gets the tracker's
            if existingHistory != nil && progress.date == nil {
                continue
            }
            if let existingDate = existingHistory?.dateRead, let newDate = progress.date, newDate <= existingDate {
                // don't update if the existing history is newer than the tracker history
                continue
            }
            // mark chapters as read
            if progress.completed {
                if !(existingHistory?.completed ?? false) {
                    let detail = "fecha \(progress.date.map { "\($0)" } ?? "ninguna"), local \(existingHistory.map { "pág \($0.progress)/\($0.total)" } ?? "sin historial")"
                    // without the server's date the manga isn't «read recently» (SUWA-12 H4)
                    let readDate = progress.date ?? Date.distantPast
                    lastRead = readDate > lastRead ? readDate : lastRead
                    plan.steps.append(.complete(chapterKey: chapterKey, date: progress.date ?? now, journalDetail: detail))
                }
            } else if progress.page != 0 {
                let readDate = progress.date ?? now
                lastRead = readDate > lastRead ? readDate : lastRead
                plan.steps.append(.progress(chapterKey: chapterKey, page: progress.page, date: readDate))
            }
        }

        // mark manga as read only if history was updated, with a date
        if !plan.steps.isEmpty && lastRead > Date.distantPast {
            plan.mangaRead = lastRead
        }
        return plan
    }
}
