//
//  ChapterValues.swift
//  Aidoku
//
//  SUWA-13 F4 L6: values of the chapter contract.
//

import AidokuRunner

/// A stored chapter and its manga, read together (nil what is not stored).
struct ChapterWithManga: Sendable, Hashable {
    var manga: AidokuRunner.Manga?
    var chapter: AidokuRunner.Chapter?
}
