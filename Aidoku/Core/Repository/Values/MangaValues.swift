//
//  MangaValues.swift
//  Aidoku
//
//  SUWA-13 F4 L6: values of the manga contract.
//

/// How the chapter list of a stored manga is shown: sort flags, language and scanlators.
struct MangaChapterFilters: Sendable, Hashable {
    var flags: Int
    var language: String?
    var scanlators: [String]?
}
