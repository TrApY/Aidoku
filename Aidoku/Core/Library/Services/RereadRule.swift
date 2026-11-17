//
//  RereadRule.swift
//  Aidoku
//
//  SUWA-17 F2: which completed chapters with a page before their last one are being read again. Completing leaves
//  a chapter at its last page (D2), but the chapters completed before that, by a sync from a tracker, on the other
//  device or with «marcar como leído» after reading some of it, keep a page before their last one: those are not
//  being read again. Nothing is rewritten: it is decided when reading.
//

import Foundation

enum RereadRule {
    /// A completed chapter (with a page before its last but one) is being read again if it was opened again after
    /// its completion: a reading session with pages read that started after the last completion recorded on this
    /// device (the journal). Without that completion (completed elsewhere, by a sync, before the journal) or
    /// without a later session (the page was saved in the visit that completed it), it is not.
    static func isRereading(chapter: ChapterIdentifier, sessionStart: Date?, journal: [String]) -> Bool {
        guard
            let sessionStart,
            let completed = CompletionJournal.lastCompletion(of: chapter, lines: journal)
        else { return false }
        return sessionStart > completed
    }

    /// The same with the completions (`CompletionJournal.latestCompletions`; SUWA-17 G3b).
    static func isRereading(chapter: ChapterIdentifier, sessionStart: Date?, completions: CompletionJournal.Completions) -> Bool {
        guard let sessionStart, let completed = completions.last(of: chapter) else { return false }
        return sessionStart > completed
    }

    /// [chapter key: page] of a manga's completed chapters being read again.
    static func rereadPages(_ entries: [String: ReadingHistoryEntry], manga: MangaIdentifier) -> [String: Int] {
        let candidates = entries.filter { $0.value.rereadPage != nil }
        guard !candidates.isEmpty else { return [:] }
        let journal = CompletionJournal.lines()
        var pages: [String: Int] = [:]
        for (key, entry) in candidates {
            let chapter = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
            guard
                let page = entry.rereadPage,
                isRereading(chapter: chapter, sessionStart: entry.rereadSessionStart, journal: journal)
            else { continue }
            pages[key] = page
        }
        return pages
    }
}
