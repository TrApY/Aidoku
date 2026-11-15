//
//  MigrationOptions.swift
//  Aidoku
//
//  What a migration takes to the new entry and what happens to the original (the migration sheet, as in
//  Tachimanga).
//

import AidokuRunner
import Foundation

struct MigrationOptions: Codable, Equatable, Sendable {
    /// Read chapters, the unfinished chapter's page, and what was read for the trackers.
    var readChapters = true
    var categories = true
    /// The trackers (AniList, MAL…). A server tracker (Suwayomi) of a server manga is registered anyway.
    var tracking = true
    /// The original stays in the library (the old «Copy»); otherwise it's replaced (the old «Migrate»).
    var keepOriginal = false
    /// Delete the original's downloads once the migration went well.
    var deleteDownloads = true

    init(
        readChapters: Bool = true,
        categories: Bool = true,
        tracking: Bool = true,
        keepOriginal: Bool = false,
        deleteDownloads: Bool = true
    ) {
        self.readChapters = readChapters
        self.categories = categories
        self.tracking = tracking
        self.keepOriginal = keepOriginal
        self.deleteDownloads = deleteDownloads
    }

    /// The old choices: «Copy» (copy), «Migrate» (not copy) and «Migrate and keep history» (copy + remove):
    /// everything is carried over and no download is deleted, as before.
    init(copy: Bool, forceRemoveFromLibrary: Bool) {
        self.init(keepOriginal: copy && !forceRemoveFromLibrary, deleteDownloads: false)
    }

    static let defaultsKey = "Migration.options"

    /// The last choice (pending: always the defaults).
    static func load(from defaults: UserDefaults = .standard) -> MigrationOptions {
        MigrationOptions()
    }

    /// Remembers this choice for the next migration (pending).
    func save(to defaults: UserDefaults = .standard) {}

    /// Delete the original's downloads? Only after the migration went well, and never when the destination
    /// is the same entry (pending).
    func shouldDeleteDownloads(old: MangaIdentifier, new: MangaIdentifier, succeeded: Bool) -> Bool {
        deleteDownloads
    }

    /// Localization keys of the notice under the options, for `count` entries (pending).
    func noteKeys(count: Int) -> [String] {
        []
    }
}

/// What a migration uses outside Core Data (injectable for tests).
struct MigrationEnvironment: @unchecked Sendable {
    var trackerLookup: @Sendable (String) -> Tracker? = { TrackerManager.getTracker(id: $0) }
    var suwayomiTracker: SuwayomiTracker? = TrackerManager.getTracker(id: "suwayomi") as? SuwayomiTracker
    var deleteDownloads: @Sendable (MangaIdentifier) async -> Void = { await DownloadManager.shared.deleteChapters(for: $0) }
    /// Bind the enhanced trackers (Suwayomi, Komga…) of the new entries afterwards.
    var bindEnhancedTrackers = true

    static var live: MigrationEnvironment { .init() }
}
