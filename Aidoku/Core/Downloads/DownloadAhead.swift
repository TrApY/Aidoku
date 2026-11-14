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

    /// Carries the setting over when a manga is migrated to another source (pending).
    static func migrate(from oldManga: MangaIdentifier, to newManga: MangaIdentifier, copy: Bool) {
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

    static func state(for status: DownloadStatus) -> ChapterState {
        switch status {
            case .finished: .downloaded
            case .none: .missing
            default: .queued // pending
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
    /// Without Wi-Fi, when downloads require it, it queues nothing and doesn't ask.
    @discardableResult
    func ensureAheadDownloaded(
        manga: AidokuRunner.Manga,
        connection: NetworkDataType? = nil
    ) async -> [AidokuRunner.Chapter] {
        let mangaId = manga.identifier
        guard
            DownloadAheadSetting.get(for: mangaId) > 0,
            manga.sourceKey != LocalSourceRunner.sourceKey,
            DownloadAheadPlanner.canQueue(
                onlyOnWifi: AppSettings.downloads.downloadOnlyOnWifi.get(),
                connection: connection ?? Reachability.getConnectionType()
            )
        else {
            return []
        }

        let runKey = DownloadAheadSetting.key(for: mangaId)
        guard await DownloadAheadRuns.shared.begin(runKey) else { return [] }
        var queuedNow: [AidokuRunner.Chapter] = []
        repeat {
            let target = DownloadAheadSetting.get(for: mangaId)
            // stored in source order (newest first): reversed is the reading order downloadUnread uses
            let chapters = await CoreDataManager.shared.getChapters(mangaId: mangaId).reversed().map { $0.toNew() }
            guard target > 0, !chapters.isEmpty else { continue }
            let readingHistory = await CoreDataManager.shared.getReadingHistory(mangaId: mangaId)
            let filters = await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getMangaChapterFilters(mangaId: mangaId, context: context)
            }
            var downloaded = Set<String>()
            var queued = Set<String>()
            for chapter in chapters {
                let identifier = ChapterIdentifier(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: chapter.key)
                switch getDownloadStatus(for: identifier) {
                    case .finished: downloaded.insert(chapter.key)
                    case .none: break
                    // queued, or failed and waiting in the queue for a manual retry
                    default: queued.insert(chapter.key)
                }
            }
            let toQueue = DownloadAheadPlanner.chaptersToQueue(
                chapters: chapters,
                readingHistory: readingHistory,
                downloaded: downloaded,
                queued: queued,
                target: target,
                language: filters.language,
                scanlators: filters.scanlators ?? []
            )
            if !toQueue.isEmpty {
                await download(manga: manga, chapters: toQueue)
                queuedNow += toQueue
            }
        } while await DownloadAheadRuns.shared.end(runKey)
        return queuedNow
    }

    /// Same, for a library manga known only by its identifier (history, library refresh).
    @discardableResult
    func ensureAheadDownloaded(mangaId: MangaIdentifier) async -> [AidokuRunner.Chapter] {
        guard DownloadAheadSetting.get(for: mangaId) > 0 else { return [] }
        let manga = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(mangaId: mangaId, context: context)?.manga?.toManga().toNew()
        }
        guard let manga else { return [] }
        return await ensureAheadDownloaded(manga: manga)
    }
}
