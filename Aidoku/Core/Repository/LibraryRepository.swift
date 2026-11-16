//
//  LibraryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L3: whether manga are in the library (L3), the library query and its reads (L7).
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
}
