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

/// One library entry as the library refresh reads it (D-L12-3): the fields of the old `Manga` that
/// `MangaObject.toManga()` fills, so that the refresh keeps each entry's identity (source and key, as the old
/// `Manga` hashes) and the values it goes by (what it skips, the chapter filters, `toNew()`).
struct LibraryRefreshEntry: Sendable, Hashable {
    var sourceId: String
    var id: String
    var title: String?
    var author: String?
    var artist: String?
    var description: String?
    var tags: [String]?
    var coverUrl: URL?
    var url: URL?
    var status: PublishingStatus
    var nsfw: MangaContentRating
    var viewer: MangaViewer
    var updateStrategy: UpdateStrategy
    var nextUpdateTime: Date?
    var chapterFlags: Int
    var langFilter: String?
    var scanlatorFilter: [String]?
    var lastOpened: Date?
    var lastUpdated: Date?
    var lastUpdatedChapters: Date?
    var lastChapter: Date?
    var lastRead: Date?
    var dateAdded: Date?
}

extension LibraryRefreshEntry {
    init(_ manga: Manga) {
        self.init(
            sourceId: manga.sourceId,
            id: manga.id,
            title: manga.title,
            author: manga.author,
            artist: manga.artist,
            description: manga.description,
            tags: manga.tags,
            coverUrl: manga.coverUrl,
            url: manga.url,
            status: manga.status,
            nsfw: manga.nsfw,
            viewer: manga.viewer,
            updateStrategy: manga.updateStrategy,
            nextUpdateTime: manga.nextUpdateTime,
            chapterFlags: manga.chapterFlags,
            langFilter: manga.langFilter,
            scanlatorFilter: manga.scanlatorFilter,
            lastOpened: manga.lastOpened,
            lastUpdated: manga.lastUpdated,
            lastUpdatedChapters: manga.lastUpdatedChapters,
            lastChapter: manga.lastChapter,
            lastRead: manga.lastRead,
            dateAdded: manga.dateAdded
        )
    }

    /// The old `Manga` the refresh loop works with, with these same fields.
    func toManga() -> Manga {
        Manga(
            sourceId: sourceId,
            id: id,
            title: title,
            author: author,
            artist: artist,
            description: description,
            tags: tags,
            coverUrl: coverUrl,
            url: url,
            status: status,
            nsfw: nsfw,
            viewer: viewer,
            updateStrategy: updateStrategy,
            nextUpdateTime: nextUpdateTime,
            chapterFlags: chapterFlags,
            langFilter: langFilter,
            scanlatorFilter: scanlatorFilter,
            lastOpened: lastOpened,
            lastUpdated: lastUpdated,
            lastUpdatedChapters: lastUpdatedChapters,
            lastChapter: lastChapter,
            lastRead: lastRead,
            dateAdded: dateAdded
        )
    }
}
