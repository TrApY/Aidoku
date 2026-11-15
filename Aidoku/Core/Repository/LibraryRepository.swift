//
//  LibraryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L3: whether manga are in the library. The library queries and writes come in L7.
//

protocol LibraryRepository: Sendable {
    func contains(_ id: MangaIdentifier) async -> Bool
    /// The ones of `ids` that are in the library, in one call however many there are (repeated ids count once).
    func contained(in ids: [MangaIdentifier]) async -> Set<MangaIdentifier>
}
