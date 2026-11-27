//
//  MangaRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L6: stored manga. The reads the screens need (the manga itself, its chapter filters, its reading
//  mode, whether a key was edited) and its cover.
//

import AidokuRunner

protocol MangaRepository: Sendable {
    /// The stored manga (without chapters); nil if it is not stored.
    func manga(_ id: MangaIdentifier) async -> AidokuRunner.Manga?
    /// Whether the manga is stored (in the library or not).
    func contains(_ id: MangaIdentifier) async -> Bool
    /// The manga's chapter flags, language and scanlators; flags 0 and no filters if it is not stored.
    func chapterFilters(_ id: MangaIdentifier) async -> MangaChapterFilters
    /// The reading mode the manga stores (its viewer); -1 if it is not stored.
    func readingMode(_ id: MangaIdentifier) async -> Int
    /// Whether that key of the manga was edited by the user (false if it is not stored).
    func hasEditedKey(_ key: EditedKeys, _ id: MangaIdentifier) async -> Bool
    /// Sets the cover and marks it as edited (with `original`, as not edited). The cover it had before; nil if the
    /// manga is not stored or the save failed, and also when it had none.
    @discardableResult func setCover(_ id: MangaIdentifier, url: String?, original: Bool) async -> String?
    /// Writes the manga's details and these chapter filters into the stored manga, as the manga screen did
    /// (D-L12-5, spec §1.5 nº 15): what the user edited stays; the chapter flags, the language, the scanlators
    /// and the next update time are always written. false if the manga is not stored or the save failed.
    @discardableResult func updateDetails(_ manga: AidokuRunner.Manga, filters: MangaChapterFilters) async -> Bool
}
