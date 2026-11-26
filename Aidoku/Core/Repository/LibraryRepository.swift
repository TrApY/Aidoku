//
//  LibraryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L3: whether manga are in the library (L3), the library query, its reads and its writes (L7), the refresh (L8).
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
    /// The library entries the library refresh goes through (all, or those in a category), each as the old
    /// `Manga` read it (D-L12-3): one per entry with a manga, in one read.
    func refreshEntries(category: String?) async -> [LibraryRefreshEntry]
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
    /// The library refresh of one manga (§1.3 nº 10): details if `updateMetadata`, chapters (setChapters, §1.5
    /// nº 11) and an update entry for each new chapter that passes the stored filters (§1.5 nº 12), saved only if
    /// something changed. nil if it is not in the library, or if the manga comes without chapters: then nothing is
    /// saved, not even the details.
    @discardableResult func refresh(_ id: MangaIdentifier, with manga: AidokuRunner.Manga, updateMetadata: Bool) async -> RefreshOutcome?
    /// The refresh from the manga's screen (§1.3 nº 11, not the same as `refresh`): always the details and a save,
    /// updates by the filters the screen shows, and «last opened» just after now unless `incognito`. nil if it is
    /// not in the library.
    func refreshOpened(
        _ id: MangaIdentifier,
        with manga: AidokuRunner.Manga,
        languageFilter: String?,
        scanlatorFilter: [String],
        incognito: Bool
    ) async -> OpenedRefresh?
    /// One entry of a manga migration (spec §1.3 nº 13, D-L11-1): the transaction MangaManager ran, moved as it
    /// was, in one context and one save. nil if the save failed (nothing is left half done). The journal, the
    /// settings, the server work and the notifications stay with MangaManager.
    func migrate(_ request: MigrationRequest) async -> MigrationOutcome?
    /// What a source's own migration looks up (D-L11-7): the source's manga in the library, its stored chapters and
    /// its history rows, read in one context.
    func identifiersToRemap(sourceKey: String) async -> IdentifiersToRemap
    /// Rewrites, in one save, the keys of a source's manga in the library, of its stored chapters and of its history
    /// rows with the new ones the source gave (spec §1.3 nº 14, D-L11-7); keys without a new one stay. false if the
    /// save failed.
    @discardableResult func remapIdentifiers(_ remap: IdentifierRemap) async -> Bool
    /// Settings' «reset», first part (D-L12-7, spec §1.3 nº 18): every library entry and every manga, two batch
    /// deletes that run at once, in one context (there is nothing to save). A failed one is logged, as before.
    func clearLibraryAndManga() async
    /// The second part, after the history: every chapter, category and track (three batch deletes, in that order)
    /// and the save there was, in one context.
    func clearChaptersCategoriesAndTracks() async
}
