//
//  MangaUpdateRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L8: the chapter updates list.
//

protocol MangaUpdateRepository: Sendable {
    /// The updates, newest first, with their manga (those whose manga is not stored are left out).
    func recent(limit: Int, offset: Int) async -> [MangaUpdateEntry]
    /// Marks the manga's unviewed updates as viewed and gives them back ([] if none, or if it did not save).
    func markViewed(of manga: MangaIdentifier) async -> [MangaUpdateItem]
    /// Removes these updates.
    @discardableResult func remove(_ chapters: [ChapterIdentifier]) async -> Bool
}
