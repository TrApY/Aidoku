//
//  LibraryValues.swift
//  Aidoku
//
//  SUWA-13 F4 L7: values of the library contract.
//

/// What the library screen asks for: which manga, in which order, with which filters (spec §2.3).
struct LibraryQuery: Sendable, Hashable {
    enum Scope: Sendable, Hashable {
        case all
        /// the manga without any category
        case uncategorized
        case category(String)
    }

    /// The order by a business criterion, not by a stored key.
    enum Sort: Sendable, Hashable, CaseIterable {
        case title
        case lastRead
        case lastOpened
        case lastUpdated
        case dateAdded
        case lastChapter
        /// not ordered here: the screen orders by its unread counts afterwards
        case unreadChapters
        case totalChapters
    }

    var scope: Scope
    var sort: Sort
    /// The real direction (the screen shows the title order the other way round; it turns it before asking).
    var ascending: Bool
    var filters: [LibraryFilter]
    /// Pins the manga with chapters newer than the last time they were opened.
    var pinUpdatedChapters: Bool
}

/// The answer to a library query.
struct LibraryPage: Sendable, Hashable {
    var pinned: [MangaInfo]
    var manga: [MangaInfo]
    /// The sources of every manga in the scope, the filtered out ones too.
    var sourceKeys: Set<String>
    /// No manga in the scope at all, before the filters.
    var isEmpty: Bool
    /// The filters only the screen can apply (downloads, unread counts), as they were met: once per manga that
    /// reached them.
    var unappliedFilters: [LibraryFilter]
}

/// What the downloads list shows of a downloaded manga that has no ComicInfo (D-L12-8).
struct DownloadedEntryInfo: Sendable, Hashable {
    var title: String?
    var cover: String?
    var isInLibrary: Bool
    /// the stored manga's key, or the directory's name if none was found
    var mangaKey: String
}
