//
//  HistoryValues.swift
//  Aidoku
//
//  SUWA-13 F4 L4-L5: what the history repository gives and takes (no Core Data objects).
//

import Foundation

/// A chapter's completion and page. `progress` nil = no history; -1 = history without a page (a history made by a
/// session or by marking it read starts at -1, spec §1.5 nº 1).
struct ChapterProgress: Sendable, Hashable {
    var completed: Bool
    var progress: Int?
}

/// One history row.
struct HistoryRecord: Sendable, Hashable {
    var chapterId: ChapterIdentifier
    var progress: Int
    var total: Int
    var completed: Bool
    var dateRead: Date?
    var scrollPosition: Double?
}

/// A chapter's entry in a manga's reading history: `page` -1 if completed; `date` the read date in whole seconds
/// since 1970, -1 if there is none.
struct ReadingHistoryEntry: Sendable, Hashable {
    var page: Int
    var date: Int
    /// A completed chapter with a page before its last but one (0 < page < total - 1, SUWA-17 D2, F2): its page;
    /// whether it is being read again is RereadRule's.
    var rereadPage: Int?
    /// For those, when its latest reading session with pages read started (SUWA-17 F2).
    var rereadSessionStart: Date?
}

extension Dictionary where Value == ReadingHistoryEntry {
    /// The shape the screens and services use: [chapter key: (page, date)].
    var pagesAndDates: [Key: (page: Int, date: Int)] {
        mapValues { (page: $0.page, date: $0.date) }
    }

}

/// A page saved by the reader (SUWA-7). `totalPages`/`scrollPosition` nil keep what was stored.
struct PageSave: Sendable, Hashable {
    var chapter: ChapterIdentifier
    var page: Int
    var totalPages: Int?
    var scrollPosition: Double?
}
