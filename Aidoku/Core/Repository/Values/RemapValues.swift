//
//  RemapValues.swift
//  Aidoku
//
//  SUWA-13 F4 L11c: a source that changed its ids (D-L11-7).
//

/// The ids a source's own migration has to look up, read in one context (AppDelegate.handleSourceMigration).
struct IdentifiersToRemap: Sendable {
    /// The keys of the source's manga in the library (an entry repeated for the same manga comes twice).
    var libraryMangaKeys: [String]
    /// (manga key, chapter key) of the source's stored chapters.
    var chapters: [(mangaKey: String, chapterKey: String)]
    /// The manga key of each history row of the source.
    var historyMangaKeys: [String]
    /// (manga key, chapter key) of each history row of the source.
    var historyChapters: [(mangaKey: String, chapterKey: String)]
}

/// The new keys a source gave for its old ones.
struct IdentifierRemap: Sendable {
    var sourceKey: String
    /// old manga key → new manga key
    var mangaKeys: [String: String]
    /// old chapter key → new chapter key
    var chapterKeys: [String: String]
}
