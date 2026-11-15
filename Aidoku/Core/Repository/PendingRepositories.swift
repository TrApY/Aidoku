//
//  PendingRepositories.swift
//  Aidoku
//
//  SUWA-13 F4: the domains still to move behind a repository (spec §2.4). Each lot gives its protocol its own file
//  and its signatures, and adds it to `DataRepositories`.
//

/// L2: categories and filter groups.
protocol CategoryRepository: Sendable {}
/// L3 and L7: library membership and the library queries.
protocol LibraryRepository: Sendable {}
/// L4 and L5: reading history.
protocol HistoryRepository: Sendable {}
/// L6: stored manga.
protocol MangaRepository: Sendable {}
/// L6: chapters.
protocol ChapterRepository: Sendable {}
/// L8: chapter updates.
protocol MangaUpdateRepository: Sendable {}
/// L9: installed sources.
protocol SourceRepository: Sendable {}
/// L10: reading sessions and insights.
protocol ReadingSessionRepository: Sendable {}
/// L10: vocabulary (the API of VocabManager).
protocol VocabRepository: Sendable {}
