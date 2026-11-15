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

    /// The last choice (the defaults the first time, or if it can't be read).
    static func load(from defaults: UserDefaults = .standard) -> MigrationOptions {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let options = try? JSONDecoder().decode(MigrationOptions.self, from: data)
        else {
            return MigrationOptions()
        }
        return options
    }

    /// What the sheet starts with: the last choice, but the defaults for a migration the app forces (a
    /// source that changed its ids or was uninstalled): nobody chose those options for it.
    static func initial(forced: Bool, defaults: UserDefaults = .standard) -> MigrationOptions {
        forced ? MigrationOptions() : load(from: defaults)
    }

    /// Remembers this choice for the next migration (as Tachimanga).
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Delete the original's downloads? Only after the migration went well, and never when the destination
    /// is the same entry (they would be its own).
    func shouldDeleteDownloads(old: MangaIdentifier, new: MangaIdentifier, succeeded: Bool) -> Bool {
        deleteDownloads && succeeded && old != new
    }

    /// Localization keys of the notice under the options, for `count` entries.
    func noteKeys(count: Int) -> [String] {
        let key = switch (keepOriginal, deleteDownloads) {
            case (false, true): "MIGRATION_NOTE_REPLACE_DELETE"
            case (false, false): "MIGRATION_NOTE_REPLACE_KEEP_DOWNLOADS"
            case (true, true): "MIGRATION_NOTE_KEEP_DELETE"
            case (true, false): "MIGRATION_NOTE_KEEP"
        }
        let many = count == 1 ? "" : "_MANY"
        var keys = [key + many]
        if !keepOriginal && !readChapters {
            keys.append("MIGRATION_NOTE_HISTORY_LOST" + many)
        }
        return keys
    }
}

/// What a migration uses outside Core Data (injectable for tests).
struct MigrationEnvironment: @unchecked Sendable {
    var trackerLookup: @Sendable (String) -> Tracker? = { TrackerManager.getTracker(id: $0) }
    var suwayomiTracker: SuwayomiTracker? = TrackerManager.getTracker(id: "suwayomi") as? SuwayomiTracker
    var deleteDownloads: @Sendable (MangaIdentifier) async -> Void = { await DownloadManager.shared.deleteChapters(for: $0) }
    /// Bind the enhanced trackers (Suwayomi, Komga…) of the new entries afterwards.
    var bindEnhancedTrackers = true
    /// Where the server work goes (nil: nobody waits for it).
    var serverTasks: MigrationServerTasks?
    /// The server work of each tracker runs in order: A→B→C done quickly must not leave B on the server.
    var serverQueue: MigrationServerQueue = .shared

    static var live: MigrationEnvironment { .init() }
}

/// Starts the server work of a migration (Suwayomi library, enhanced trackers) without making the
/// migration wait; tests keep the tasks to wait for them or cancel them.
/// One queue per tracker for the server work of migrations: each job starts when the previous one of the
/// same tracker has finished.
final class MigrationServerQueue: @unchecked Sendable {
    static let shared = MigrationServerQueue()

    private let lock = NSLock()
    private var last: [String: Task<Void, Never>] = [:]

    func enqueue(_ trackerId: String, _ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = last[trackerId]
            let task = Task {
                await previous?.value
                await work()
            }
            last[trackerId] = task
            return task
        }
    }
}

final class MigrationServerTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        lock.withLock { tasks.append(task) }
    }

    func waitAll() async {
        for task in lock.withLock({ tasks }) {
            await task.value
        }
    }

    func cancelAll() {
        lock.withLock { tasks }.forEach { $0.cancel() }
    }
}

/// What a migration does with one track item of the old entry.
enum MigrationTrackAction: Equatable, Sendable {
    /// Leave it as it is (on the old entry).
    case keep
    /// Delete it (the old entry leaves the library and nothing can follow the new one).
    case delete
    /// Point it at the new entry; with `id`, also a new track id (Suwayomi: each server manga has its own).
    case move(id: String?)
    /// A new track item for the new entry with this id (the old entry keeps its own).
    case copy(id: String)
}

extension MigrationOptions {
    /// - suwayomiNewTrackId: the item is the Suwayomi tracker's; the new entry's track id if it's a server
    ///   manga (nil: it isn't). A server tracker follows the entry whatever `tracking` says.
    /// - newHasTrack: the new entry already has an item of that tracker.
    /// - canTrackNew: the item's tracker exists and can track the new entry.
    static func trackAction(
        isSuwayomi: Bool,
        trackId: String,
        suwayomiNewTrackId: String?,
        keepOriginal: Bool,
        sameEntry: Bool,
        newHasTrack: Bool,
        tracking: Bool,
        canTrackNew: Bool
    ) -> MigrationTrackAction {
        let replacing = !keepOriginal && !sameEntry
        if isSuwayomi {
            // the server tracks each manga by its own id: it follows the new manga if that's a server one
            guard let newId = suwayomiNewTrackId, !sameEntry else {
                return replacing ? .delete : .keep
            }
            if keepOriginal {
                return newHasTrack ? .keep : .copy(id: newId)
            }
            return newHasTrack ? .delete : .move(id: newId)
        }
        guard tracking, !newHasTrack, canTrackNew, !sameEntry else {
            return replacing ? .delete : .keep
        }
        return keepOriginal ? .copy(id: trackId) : .move(id: nil)
    }
}
