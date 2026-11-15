//
//  HistoryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L4: reading history and progress, the READS (the writes come in L5).
//

import Foundation

protocol HistoryRepository: Sendable {
    func progress(of chapter: ChapterIdentifier) async -> ChapterProgress
    func record(of chapter: ChapterIdentifier) async -> HistoryRecord?
    /// [chapter key: entry] of a manga. It WRITES, as it always did (spec §1.5 nº 4): it removes repeated
    /// histories of a chapter (keeping one of them) and, if the manga is in the library, links each history
    /// without chapter to its chapter.
    func readingHistory(of manga: MangaIdentifier) async -> [String: ReadingHistoryEntry]
    /// Newest read first; same date: highest chapter number first (spec §1.5 nº 6).
    func recent(limit: Int, offset: Int) async -> [HistoryRecord]
    func hasHistory(of manga: MangaIdentifier) async -> Bool
    /// The earliest read date of the manga's completed chapters.
    func earliestReadDate(of manga: MangaIdentifier) async -> Date?
    /// The highest number read (completed) as `mode` counts it; the caller gives the mode (it used to be read from the
    /// settings inside, §1.5 nº 5; ChapterTitleDisplayMode.stored(for:) gives the stored one).
    func highestReadNumber(of manga: MangaIdentifier, mode: ChapterTitleDisplayMode) async -> Float?
}
