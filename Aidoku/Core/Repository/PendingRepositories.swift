//
//  PendingRepositories.swift
//  Aidoku
//
//  SUWA-13 F4: the domains still to move behind a repository (spec §2.4). Each lot gives its protocol its own file
//  and its signatures, and adds it to `DataRepositories`.
//

/// L6: stored manga.
/// L8: chapter updates.
/// L9: installed sources.
protocol SourceRepository: Sendable {}
/// L10: vocabulary (the API of VocabManager).
protocol VocabRepository: Sendable {}
