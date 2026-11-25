//
//  MigrationValues.swift
//  Aidoku
//
//  SUWA-13 F4 L11a: what a manga migration takes and gives (D-L11-1). MangaManager decides everything that is not
//  the store before the call, and does what depends on the result after it.
//

import AidokuRunner
import Foundation

/// One entry of a manga migration, as MangaManager decided it before the transaction.
struct MigrationRequest: Sendable {
    var options: MigrationOptions
    var old: AidokuRunner.Manga
    var new: AidokuRunner.Manga
    var newChapters: [AidokuRunner.Chapter]
    /// Keeping the original: the new manga was already stored before it was added (it keeps its own categories).
    var newWasInLibrary: Bool
    /// The server tracker (Suwayomi), if there is one, and the id its plan gives the new manga.
    var suwayomiTrackerId: String?
    var suwayomiNewTrackId: String?
    /// Whether a tracker of the user's (by id) can track the new manga; asked only for trackers that are not the
    /// server's, inside the transaction, as before.
    var canTrackNew: @Sendable (String) -> Bool
}

/// A migration that was saved.
struct MigrationOutcome: Sendable {
    /// A chapter the migration completed, and why (for the service's completion journal, written after the save).
    struct Completion: Sendable, Equatable {
        var chapter: ChapterIdentifier
        var reason: String
    }

    var from: AidokuRunner.Manga
    var to: AidokuRunner.Manga
    /// In the order they were completed.
    var completions: [Completion]
}
