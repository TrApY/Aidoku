//
//  ReadingSessionRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L5: reading sessions; L10: the insights. A session is its own save, apart from the page.
//

protocol ReadingSessionRepository: Sendable {
    /// Adds a session to the chapter's history (creating it, with read date = the session's end, if there is none).
    @discardableResult func add(_ data: HistoryManager.ReadingSessionData, chapter: ChapterIdentifier) async -> Bool
    /// The four statistics (streaks, counts, yearly chart, heatmap) as they are computed today, in one context.
    func insights() async -> InsightsSnapshot
}
