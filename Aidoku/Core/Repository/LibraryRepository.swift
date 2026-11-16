//
//  LibraryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L3: whether manga are in the library (L3), the library query, its reads and its writes (L7).
//

import AidokuRunner

protocol LibraryRepository: Sendable {
    func contains(_ id: MangaIdentifier) async -> Bool
    /// The ones of `ids` that are in the library, in one call however many there are (repeated ids count once).
    func contained(in ids: [MangaIdentifier]) async -> Set<MangaIdentifier>
    /// The library screen's query: entries with a manga in the scope, each manga once (the first in the order),
    /// with the filters applied but those in `unappliedFilters`; nil if the query failed.
    func page(_ query: LibraryQuery) async -> LibraryPage?
    /// The manga in the library from a source (an entry repeated for the same manga comes twice).
    func entries(sourceKey: String) async -> [AidokuRunner.Manga]
    /// The manga in the library, all of them or those in a category.
    func entries(category: String?) async -> [AidokuRunner.Manga]
    /// The manga if it is in the library, read as download ahead did (through the old `Manga`).
    func entry(_ id: MangaIdentifier) async -> AidokuRunner.Manga?
    /// The sources with manga in the library.
    func sourceKeysInLibrary() async -> Set<String>
    /// Library entries whose manga is from one of these sources; nil if the count failed.
    func countInLibrary(sourceKeys: [String]) async -> Int?
    /// Adds the manga (stored if it is not) and its chapters to the library, without looking for an entry it may
    /// already have (§1.5 nº 8), in one save. `adoptChapterFlags` gets the stored chapter flags and gives the new
    /// ones (nil: keep them); the default category is added if it exists.
    @discardableResult func add(
        _ manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter],
        defaultCategory: String?,
        adoptChapterFlags: (@Sendable (Int) -> Int?)?
    ) async -> Bool
    /// Removes one manga from the library: the manga (only its entry if it is a local file), its chapters and its
    /// tracks, in one save (§1.3 nº 7).
    @discardableResult func remove(_ id: MangaIdentifier) async -> LibraryRemovalResult
    /// Removes several, in batches of 100, in one save (§1.3 nº 8).
    @discardableResult func remove(_ ids: [MangaIdentifier]) async -> LibraryRemovalResult
    /// What undoing the removal of these manga needs, in their order (those not stored are left out).
    func snapshot(_ ids: [MangaIdentifier]) async -> [LibrarySnapshot]
    /// Puts a removed manga back (§1.3 nº 9): entry, chapters, dates, tracks (without their chapter offset, as
    /// today) and categories (created if missing), in one save.
    @discardableResult func restore(_ snapshot: LibrarySnapshot) async -> Bool
    /// The entry's «last opened» becomes now (nothing to do if it is not in the library).
    @discardableResult func markOpened(_ id: MangaIdentifier) async -> Bool
    /// Entries whose «chapters updated» date is the old default take their «updated» date. As today, it is never
    /// saved: nothing stored changes.
    func resetLastUpdatedChapters() async
}
