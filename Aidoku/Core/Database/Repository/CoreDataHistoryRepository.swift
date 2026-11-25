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

    static func record(_ object: HistoryObject) -> HistoryRecord {
        HistoryRecord(
            chapterId: object.identifier,
            progress: Int(object.progress),
            total: Int(object.total),
            completed: object.completed,
            dateRead: object.dateRead,
            scrollPosition: object.scrollPosition?.doubleValue
        )
    }

    static func progress(_ stored: (completed: Bool, progress: Int?)) -> ChapterProgress {
        ChapterProgress(completed: stored.completed, progress: stored.progress)
    }

    func progress(of chapter: ChapterIdentifier) async -> ChapterProgress {
        await container.performBackgroundTask { context in
            Self.progress(CoreDataManager.shared.getProgress(chapterId: chapter, context: context))
        }
    }

    func record(of chapter: ChapterIdentifier) async -> HistoryRecord? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getHistory(chapterId: chapter, context: context).map(Self.record)
        }
    }

    /// The start of the history's latest reading session with pages read (SUWA-17 F2).
    static func latestSessionStart(of history: HistoryObject) -> Date? {
        (history.sessions as? Set<ReadingSessionObject>)?
            .filter { $0.pagesRead > 0 }
            .compactMap { session -> Date? in session.startDate }
            .max()
    }

    func readingHistory(of manga: MangaIdentifier) async -> [String: ReadingHistoryEntry] {
        await container.performBackgroundTask { context in
            var entries = CoreDataManager.shared.getReadingHistory(mangaId: manga, context: context)
                .mapValues { ReadingHistoryEntry(page: $0.page, date: $0.date) }
            // the completed chapters with a page before their last but one, and when they were last opened (the
            // service decides which are being read again: SUWA-17 D2, F2)
            for history in CoreDataManager.shared.getHistoryForManga(mangaId: manga, context: context)
            where history.completed && history.progress > 0 && history.progress < history.total - 1 {
                entries[history.chapterId]?.rereadPage = Int(history.progress)
                entries[history.chapterId]?.rereadSessionStart = Self.latestSessionStart(of: history)
            }
            return entries
        }
    }

    func recent(limit: Int, offset: Int) async -> [HistoryRecord] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getRecentHistory(limit: limit, offset: offset, context: context).map(Self.record)
        }
    }

    func hasHistory(of manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasHistory(mangaId: manga, context: context)
        }
    }

    func earliestReadDate(of manga: MangaIdentifier) async -> Date? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getEarliestReadDate(mangaId: manga, context: context)
        }
    }

    func highestReadNumber(of manga: MangaIdentifier, mode: ChapterTitleDisplayMode) async -> Float? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getHighestReadNumber(mangaId: manga, mode: mode, context: context)
        }
    }

    // MARK: writes

    @discardableResult
    func savePage(_ save: PageSave) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.setRead(mangaId: save.chapter.mangaIdentifier, context: context)
            CoreDataManager.shared.setProgress(
                save.page,
                chapterId: save.chapter,
                totalPages: save.totalPages,
                scrollPosition: save.scrollPosition,
                context: context
            )
            return context.saveLogging("HistoryManager.setProgress")
        }
    }

    @discardableResult
    func savePosition(_ save: PageSave) async -> Bool {
        await container.performBackgroundTask { context in
            guard
                let scrollPosition = save.scrollPosition,
                let object = CoreDataManager.shared.getHistory(chapterId: save.chapter, context: context),
                Int(object.progress) == save.page
            else { return false }
            guard object.scrollPosition?.doubleValue != scrollPosition else { return true }
            object.scrollPosition = NSNumber(value: scrollPosition)
            return context.saveLogging("HistoryManager.setPosition")
        }
    }

    @discardableResult
    func markCompleted(_ chapters: [ChapterIdentifier], date: Date) async -> Bool? {
        await container.performBackgroundTask { context in
            guard CoreDataManager.shared.setCompleted(chapterIds: chapters, date: date, context: context) else {
                return false
            }
            if let mangaId = chapters.first?.mangaIdentifier {
                CoreDataManager.shared.setRead(mangaId: mangaId, date: date, context: context)
            }
            return context.saveLogging("HistoryManager.addHistory") ? true : nil
        }
    }

    @discardableResult
    func remove(chapters: [ChapterIdentifier]) async -> Bool {
        await container.performBackgroundTask { context in
            for chapter in chapters {
                if let object = CoreDataManager.shared.getHistory(chapterId: chapter, context: context) {
                    context.delete(object)
                }
            }
            return context.saveLogging("CoreDataManager.removeHistory(sourceId:mangaId:chapterIds:)")
        }
    }

    @discardableResult
    func removeAll(of manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.removeHistory(mangaId: manga, context: context)
            return context.saveLogging("HistoryRepository.removeAll")
        }
    }

    @discardableResult
    func clear(excludingLibrary: Bool) async -> Bool {
        await container.performBackgroundTask { context in
            if excludingLibrary {
                CoreDataManager.shared.clearHistoryExcludingLibrary(context: context)
            } else {
                CoreDataManager.shared.clearHistory(context: context)
            }
            return context.saveLogging("HistoryRepository.clear")
        }
    }

    func applyTrackerSync(mangaId: MangaIdentifier, remote: [String: ChapterReadProgress]) async -> TrackerSyncResult {
        await container.performBackgroundTask { context in
            func chapterId(_ chapterKey: String) -> ChapterIdentifier {
                ChapterIdentifier(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: chapterKey)
            }
            // the local history read in the same context the plan is written in: the comparison of dates stays
            // atomic with the save
            var local: [String: TrackerSyncLocal] = [:]
            for chapterKey in remote.keys {
                if let existingHistory = CoreDataManager.shared.getHistory(chapterId: chapterId(chapterKey), context: context) {
                    local[chapterKey] = TrackerSyncLocal(
                        completed: existingHistory.completed,
                        progress: Int(existingHistory.progress),
                        total: Int(existingHistory.total),
                        dateRead: existingHistory.dateRead
                    )
                }
            }
            let plan = TrackerSyncPlanner.plan(local: local, remote: remote)
            for step in plan.steps {
                switch step {
                    case let .complete(chapterKey, date, _):
                        CoreDataManager.shared.setCompleted(
                            chapterIds: [chapterId(chapterKey)],
                            date: date,
                            context: context
                        )
                    case let .progress(chapterKey, page, date):
                        CoreDataManager.shared.setProgress(
                            page,
                            chapterId: chapterId(chapterKey),
                            dateRead: date,
                            completed: false,
                            context: context
                        )
                }
            }
            if let date = plan.mangaRead {
                CoreDataManager.shared.setRead(
                    mangaId: mangaId,
                    date: date,
                    context: context
                )
            }
            let saved = context.saveLogging("TrackerManager.syncPageTrackerHistory")
            return TrackerSyncResult(saved: saved, plan: plan)
        }
    }
}
