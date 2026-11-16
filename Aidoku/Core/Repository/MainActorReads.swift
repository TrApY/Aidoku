//
//  MainActorReads.swift
//  Aidoku
//
//  SUWA-13 F4 (D8): synchronous reads on the main thread, only for the places that cannot wait without changing
//  the order things happen in (the reader opening a chapter, the tracking badge). Retired in F9/F11.
//

@MainActor
protocol MainActorReads: Sendable {
    /// Whether the manga has any track item (TrackerManager.isTracking).
    func isTracking(_ manga: MangaIdentifier) -> Bool
    /// The page the reader opens a chapter at (ReaderViewController.loadCurrentChapter).
    func progress(of chapter: ChapterIdentifier) -> ChapterProgress
    /// The stored scroll position of the page it opens at (ReaderViewController.openingPageKey).
    func record(of chapter: ChapterIdentifier) -> HistoryRecord?
    /// Whether the manga is stored (the reader's reading mode «auto»).
    func manga(contains id: MangaIdentifier) -> Bool
    /// The reading mode the manga stores; -1 if it is not stored.
    func readingMode(of id: MangaIdentifier) -> Int
}
