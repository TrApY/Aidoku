//
//  PendingRepositories.swift
//  Aidoku
//
//  SUWA-13 F4: the domains still to move behind a repository (spec §2.4). Each lot gives its protocol its own file
//  and its signatures, and adds it to `DataRepositories`.
//

/// L6: stored manga.
protocol MangaRepository: Sendable {}
/// L8: chapter updates.
protocol MangaUpdateRepository: Sendable {}
/// L9: installed sources.
protocol SourceRepository: Sendable {}
/// L10: vocabulary (the API of VocabManager).
protocol VocabRepository: Sendable {}
