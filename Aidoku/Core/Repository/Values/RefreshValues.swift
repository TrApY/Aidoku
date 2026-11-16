//
//  RefreshValues.swift
//  Aidoku
//
//  SUWA-13 F4 L8: values of the library refresh and of the chapter updates.
//

import AidokuRunner
import Foundation

/// A library refresh of one manga (§1.3 nº 10).
struct RefreshOutcome: Sendable, Hashable {
    /// chapters it had not stored (a chapter that stops being locked is new again)
    var newChapterCount: Int
    /// those of them that made an update entry
    var notifiableCount: Int
    /// the stored title after the refresh
    var title: String
}

/// A refresh from the manga's screen (§1.3 nº 11): the stored manga after it, and whether there were new chapters.
struct OpenedRefresh: Sendable, Hashable {
    var manga: AidokuRunner.Manga
    var foundNewChapters: Bool
}

/// An entry of the updates list with its manga.
struct MangaUpdateEntry: Sendable, Hashable {
    var id: String
    var chapterId: ChapterIdentifier
    var date: Date?
    var manga: AidokuRunner.Manga
    /// the stored chapter as the list read it (through the old `Chapter`), and its place in the source
    var chapter: AidokuRunner.Chapter?
    var chapterSourceOrder: Int?
    var viewed: Bool
}
