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

    static func key(for manga: MangaIdentifier) -> String {
        "DownloadAhead.\(manga.sourceKey).\(manga.mangaKey)"
    }

    static func get(for manga: MangaIdentifier) -> Int {
        0 // pending
    }

    static func set(_ value: Int, for manga: MangaIdentifier) {
        // pending
    }
}

enum DownloadAheadPlanner {
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
        [] // pending
    }

    /// Automatic triggers never ask: without Wi-Fi (when required) they just don't queue.
    static func canQueue(onlyOnWifi: Bool, connection: NetworkDataType) -> Bool {
        true // pending
    }
}

extension DownloadManager {
    /// Queues what's missing of the manga's «descarga adelantada» window. Returns the queued chapters.
    @discardableResult
    func ensureAheadDownloaded(
        manga: AidokuRunner.Manga,
        connection: NetworkDataType? = nil
    ) async -> [AidokuRunner.Chapter] {
        [] // pending
    }

    /// Same, for a library manga known only by its identifier (history, library refresh).
    @discardableResult
    func ensureAheadDownloaded(mangaId: MangaIdentifier) async -> [AidokuRunner.Chapter] {
        [] // pending
    }
}
