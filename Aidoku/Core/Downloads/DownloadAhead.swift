//
//  DownloadAhead.swift
//  Aidoku
//
//  «Descarga adelantada»: keep the next N chapters of a manga downloaded (per manga setting).
//

import AidokuRunner
import Foundation

/// Per manga setting, stored in UserDefaults like the per manga reading mode (`Reader.readingMode.<id>`):
/// no Core Data migration, but it doesn't travel in backups nor iCloud.
enum DownloadAheadSetting {
    /// Choices offered in the manga page (0 = off).
    static let options = [0, 1, 2, 3, 5, 10]

    /// Menu text of an option.
    static func title(for option: Int) -> String {
        switch option {
            case ...0: NSLocalizedString("DOWNLOAD_AHEAD_OFF")
            case 1: NSLocalizedString("DOWNLOAD_AHEAD_ONE")
            default: String(format: NSLocalizedString("DOWNLOAD_AHEAD_CHAPTERS"), option)
        }
    }

    static func key(for manga: MangaIdentifier) -> String {
        "DownloadAhead.\(manga.sourceKey).\(manga.mangaKey)"
    }

    static func get(for manga: MangaIdentifier) -> Int {
        max(0, UserDefaults.standard.integer(forKey: key(for: manga)))
    }

    /// Carries the setting over when a manga is migrated to another source (like the reading mode),
    /// without overwriting a value the destination already has. Call once the migration succeeded.
    static func migrate(from oldManga: MangaIdentifier, to newManga: MangaIdentifier, copy: Bool) {
        let value = get(for: oldManga)
        guard value > 0, oldManga != newManga else { return }
        if get(for: newManga) == 0 {
            set(value, for: newManga)
        }
        if !copy {
            set(0, for: oldManga)
        }
    }

    static func set(_ value: Int, for manga: MangaIdentifier) {
        if value > 0 {
            UserDefaults.standard.set(value, forKey: key(for: manga))
        } else {
            UserDefaults.standard.removeObject(forKey: key(for: manga))
        }
    }
}

enum DownloadAheadPlanner {
    /// How the planner counts a chapter's download status.
    enum ChapterState: Equatable {
        case downloaded
        case queued
        case missing
    }

    /// Downloaded and queued chapter keys from their download status. A failed chapter is missing (queued
    /// again) unless this trigger already queued it once (`retried`): at most one retry per trigger.
    static func split(
        statuses: [(key: String, status: DownloadStatus)],
        retried: Set<String>
    ) -> (downloaded: Set<String>, queued: Set<String>) {
        var downloaded = Set<String>()
        var queued = Set<String>()
        for (key, status) in statuses {
            switch state(for: status) {
                case .downloaded: downloaded.insert(key)
                case .queued: queued.insert(key)
                case .missing:
                    // failed again after being queued by this trigger: leave it for the next one
                    if status == .failed && retried.contains(key) {
                        queued.insert(key)
                    }
            }
        }
        return (downloaded, queued)
    }

    static func state(for status: DownloadStatus) -> ChapterState {
        switch status {
            case .finished: .downloaded
            case .queued, .downloading, .paused: .queued
            // a failed download is no longer in the queue (DownloadQueue.downloadFailed): queue it again
            case .failed, .cancelled, .none: .missing
        }
    }

    /// Chapters to queue so that the next `target` chapters after the last read one are downloaded or queued.
    /// - Parameters:
    ///   - chapters: in reading order, oldest first (as `downloadUnread` queues them).
    ///   - readingHistory: by chapter key; `page == -1` is completed.
    ///   - downloaded, queued: chapter keys already downloaded / in the download queue.
    ///   - language, scanlators: the manga's chapter filters, as the manga page applies them.
    static func chaptersToQueue(
        chapters: [AidokuRunner.Chapter],
        readingHistory: [String: (page: Int, date: Int)],
        downloaded: Set<String>,
        queued: Set<String>,
        target: Int,
        language: String? = nil,
        scanlators: [String] = []
    ) -> [AidokuRunner.Chapter] {
        guard target > 0 else { return [] }
        let isCompleted: (AidokuRunner.Chapter) -> Bool = { readingHistory[$0.key]?.page == -1 }
        let listed = chapters.filter { matches($0, language: language, scanlators: scanlators) }
        // the window starts after the most recent read chapter in reading order (unread ones before it don't count)
        let start = listed.lastIndex(where: isCompleted).map { $0 + 1 } ?? 0
        var window: [AidokuRunner.Chapter] = []
        for chapter in listed[start...] where !chapter.locked && !isCompleted(chapter) {
            window.append(chapter)
            if window.count == target { break }
        }
        return window.filter { !downloaded.contains($0.key) && !queued.contains($0.key) }
    }

    /// Same language and scanlator filter as the manga page's chapter list.
    private static func matches(_ chapter: AidokuRunner.Chapter, language: String?, scanlators: [String]) -> Bool {
        if let language, chapter.language != language {
            return false
        }
        if !scanlators.isEmpty {
            if let chapterScanlators = chapter.scanlators, !chapterScanlators.isEmpty {
                return scanlators.contains(where: chapterScanlators.contains)
            }
            return scanlators.contains("")
        }
        return true
    }

    /// Automatic triggers never ask: without Wi-Fi (when required) they just don't queue.
    static func canQueue(onlyOnWifi: Bool, connection: NetworkDataType) -> Bool {
        !onlyOnWifi || connection == .wifi
    }
}

/// One run per manga at a time: a trigger arriving meanwhile makes the running one plan again,
/// so two triggers can't both see a chapter as missing and queue it twice.
private actor DownloadAheadRuns {
    static let shared = DownloadAheadRuns()

    private var running: Set<String> = []
    private var again: Set<String> = []

    func begin(_ key: String) -> Bool {
        if running.contains(key) {
            again.insert(key)
            return false
        }
        running.insert(key)
        return true
    }

    /// Ends the run; true if another trigger asked meanwhile (the run continues).
    func end(_ key: String) -> Bool {
        if again.remove(key) != nil {
            return true
        }
        running.remove(key)
        return false
    }
}

extension DownloadManager {
    /// Queues what's missing of the manga's «descarga adelantada» window, using the stored chapters,
    /// reading history and chapter filters of the (library) manga. Returns the queued chapters.
    /// Without Wi-Fi, when downloads require it, it queues nothing and doesn't ask. A paused queue
    /// stays paused. A failed chapter is queued again, at most once per trigger.
    @discardableResult
    func ensureAheadDownloaded(
        manga: AidokuRunner.Manga,
        connection: NetworkDataType? = nil,
        onlyOnWifi: Bool? = nil,
        connectionProvider: (@Sendable () -> NetworkDataType)? = nil
    ) async -> [AidokuRunner.Chapter] {
        let mangaId = manga.identifier
        let canQueue = {
            DownloadAheadPlanner.canQueue(
                onlyOnWifi: onlyOnWifi ?? AppSettings.downloads.downloadOnlyOnWifi.get(),
                connection: connection ?? connectionProvider?() ?? Reachability.getConnectionType()
            )
        }
        guard
            DownloadAheadSetting.get(for: mangaId) > 0,
            manga.sourceKey != LocalSourceRunner.sourceKey,
            canQueue()
        else {
            return []
        }

        let runKey = DownloadAheadSetting.key(for: mangaId)
        guard await DownloadAheadRuns.shared.begin(runKey) else { return [] }
        var queuedNow: [AidokuRunner.Chapter] = []
        var retried = Set<String>()
        repeat {
            // a pending trigger may come after the connection changed
            guard canQueue() else { continue }
            let target = DownloadAheadSetting.get(for: mangaId)
            // stored in source order (newest first): reversed is the reading order downloadUnread uses
            let chapters = await CoreDataManager.shared.getChapters(mangaId: mangaId).reversed().map { $0.toNew() }
            guard target > 0, !chapters.isEmpty else { continue }
            let readingHistory = await CoreDataManager.shared.getReadingHistory(mangaId: mangaId)
            let filters = await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getMangaChapterFilters(mangaId: mangaId, context: context)
            }
            let (downloaded, queued) = DownloadAheadPlanner.split(
                statuses: chapters.map {
                    ($0.key, getDownloadStatus(for: .init(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: $0.key)))
                },
                retried: retried
            )
            let toQueue = DownloadAheadPlanner.chaptersToQueue(
                chapters: chapters,
                readingHistory: readingHistory,
                downloaded: downloaded,
                queued: queued,
                target: target,
                language: filters.language,
                scanlators: filters.scanlators ?? []
            )
            // the connection may have changed while reading the library (several awaits)
            if !toQueue.isEmpty && canQueue() {
                retried.formUnion(toQueue.map(\.key))
                // automatic: don't resume a queue the user paused
                await download(manga: manga, chapters: toQueue, start: .unlessUserPaused)
                queuedNow += toQueue
            }
        } while await DownloadAheadRuns.shared.end(runKey)
        return queuedNow
    }

    /// Same, for a library manga known only by its identifier (history, library refresh).
    @discardableResult
    func ensureAheadDownloaded(mangaId: MangaIdentifier, onlyOnWifi: Bool? = nil) async -> [AidokuRunner.Chapter] {
        guard DownloadAheadSetting.get(for: mangaId) > 0 else { return [] }
        let manga = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(mangaId: mangaId, context: context)?.manga?.toManga().toNew()
        }
        guard let manga else { return [] }
        return await ensureAheadDownloaded(manga: manga, onlyOnWifi: onlyOnWifi)
    }
}
