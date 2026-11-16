//
//  ChapterRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L4: stored chapters, the reads the history screens and the reader need (L4) and the unread and read counts (L6).
//

import AidokuRunner

protocol ChapterRepository: Sendable {
    /// The manga's stored chapters in source order (as the source lists them: newest first).
    func chapters(of manga: MangaIdentifier) async -> [AidokuRunner.Chapter]
    func chapter(_ id: ChapterIdentifier) async -> AidokuRunner.Chapter?
    /// Unread chapters of the manga with its own filters (language and scanlators): not locked, and without history
    /// or with history not completed (only history linked to the chapter counts). With scanlators, a chapter
    /// without scanlator counts only if they include "" (§1.5 nº 10); no scanlators, or [], is all of them.
    func unreadCount(of manga: MangaIdentifier) async -> Int
    /// The same for several manga at once, each with its own filters (0 for one with no chapters).
    func unreadCounts(of mangas: [MangaIdentifier]) async -> [MangaIdentifier: Int]
    /// The same with these filters (the manga's own, already known).
    func unreadCount(of manga: MangaIdentifier, language: String?, scanlators: [String]?) async -> Int
    /// Read (completed and linked) chapters with these filters. Unlike the unread count, locked chapters count,
    /// and scanlators [] is not «all»: it counts none.
    func readCount(of manga: MangaIdentifier, language: String?, scanlators: [String]?) async -> Int
}
