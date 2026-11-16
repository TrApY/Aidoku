//
//  LibraryWriteValues.swift
//  Aidoku
//
//  SUWA-13 F4 L7: values of the library writes.
//

import AidokuRunner
import Foundation

/// The dates of a library entry.
struct LibraryDates: Sendable, Hashable {
    var dateAdded: Date
    var lastOpened: Date
    var lastUpdated: Date
    var lastUpdatedChapters: Date
    var lastChapter: Date?
    var lastRead: Date?
}

/// What undoing a removal from the library needs, read before removing (as the library screen read it: the manga
/// and its chapters through the old `Manga` and `Chapter`).
struct LibrarySnapshot: Sendable {
    var manga: AidokuRunner.Manga
    var chapters: [AidokuRunner.Chapter]
    /// nil when one of the four required dates was not known: the restored entry keeps its new dates
    var dates: LibraryDates?
    var tracks: [TrackItem]
    var categories: [String]
}

/// A removal from the library: the chapter flags each stored manga had before (the service decides about its local
/// order, SUWA-12 H6) and whether it saved (the services go on either way, as before).
struct LibraryRemovalResult: Sendable, Hashable {
    var chapterFlagsBefore: [MangaIdentifier: Int]
    var saved: Bool
}
