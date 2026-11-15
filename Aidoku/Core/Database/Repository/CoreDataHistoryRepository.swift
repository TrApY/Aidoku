//
//  CoreDataHistoryRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataHistoryRepository: HistoryRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    // STUB (rojo de L4): el contrato aún no tiene implementación
    func progress(of chapter: ChapterIdentifier) async -> ChapterProgress { ChapterProgress(completed: false, progress: nil) }
    func record(of chapter: ChapterIdentifier) async -> HistoryRecord? { nil }
    func readingHistory(of manga: MangaIdentifier) async -> [String: ReadingHistoryEntry] { [:] }
    func recent(limit: Int, offset: Int) async -> [HistoryRecord] { [] }
    func hasHistory(of manga: MangaIdentifier) async -> Bool { false }
    func earliestReadDate(of manga: MangaIdentifier) async -> Date? { nil }
    func highestReadNumber(of manga: MangaIdentifier, mode: ChapterTitleDisplayMode) async -> Float? { nil }
}
