//
//  HistoryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L4-L5: reading history and progress. Writes return whether the save went well (D1); the
//  notifications, the trackers and the completion journal stay with HistoryManager, after the await (D6).
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
    /// `highestReadNumber` and `earliestReadDate` in one read, as registering a tracker needs them (D-L12-4).
    func readState(of manga: MangaIdentifier, mode: ChapterTitleDisplayMode) async -> HistoryReadState

    // MARK: writes

    /// The reader's page (SUWA-7, spec §1.3 nº 1): the manga's last read date (if it is in the library) and the
    /// chapter's page, read date now, total and scroll position (if given) in one save. It never un-completes.
    @discardableResult func savePage(_ save: PageSave) async -> Bool
    /// Only where in the page the reader is (SUWA-19 revisión, hallazgo 2): the chapter's scroll position, if its history
    /// is at `save.page`. Not the read date, nor the manga's last read date: moving inside the page a chapter opened at
    /// is not reading. false: nothing written (no history, another page, or the save failed).
    @discardableResult func savePosition(_ save: PageSave) async -> Bool
    /// Completes the chapters not completed yet (read date `date`) and, if any, sets the manga's last read date to
    /// `date`, in one save (§1.3 nº 3). nil: it did not save; false: nothing new (nothing is saved); true: saved.
    @discardableResult func markCompleted(_ chapters: [ChapterIdentifier], date: Date) async -> Bool?
    /// Removes the history of exactly these chapters.
    @discardableResult func remove(chapters: [ChapterIdentifier]) async -> Bool
    /// Removes every history row of the manga.
    @discardableResult func removeAll(of manga: MangaIdentifier) async -> Bool
    /// Removes all history; with `excludingLibrary`, the history of manga in the library stays.
    @discardableResult func clear(excludingLibrary: Bool) async -> Bool
    /// The page trackers' progress (chapter key → progress) brought to the manga's local history (spec §1.3 nº 5,
    /// D-L11-6): in one context it reads the local history of those chapters, plans with TrackerSyncPlanner and
    /// writes the plan, in one save. The journal and the notifications stay with the service, after the await.
    func applyTrackerSync(mangaId: MangaIdentifier, remote: [String: ChapterReadProgress]) async -> TrackerSyncResult
}
