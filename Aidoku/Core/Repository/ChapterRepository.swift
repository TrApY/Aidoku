//
//  ChapterRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L4: stored chapters, the reads the history screens and the reader need (the rest comes in L6).
//

import AidokuRunner

protocol ChapterRepository: Sendable {
    /// The manga's stored chapters in source order (as the source lists them: newest first).
    func chapters(of manga: MangaIdentifier) async -> [AidokuRunner.Chapter]
    func chapter(_ id: ChapterIdentifier) async -> AidokuRunner.Chapter?
}
