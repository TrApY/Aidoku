//
//  HistoryManager.swift
//  Aidoku
//
//  Created by Skitty on 1/9/23.
//

import AidokuRunner
import Foundation

final class HistoryManager: Sendable {
    static let shared = HistoryManager()
}

extension HistoryManager {
    func setProgress(
        chapterId: ChapterIdentifier,
        chapter: AidokuRunner.Chapter,
        progress: Int,
        totalPages: Int? = nil,
        scrollPosition: Double? = nil,
        completed: Bool,
        updateTrackers: Bool = true
    ) async {
        let mangaId = chapterId.mangaIdentifier
        // the manga's last read date and the chapter's page, in one save (SUWA-7)
        await DataRepositories.shared.history.savePage(
            PageSave(chapter: chapterId, page: progress, totalPages: totalPages, scrollPosition: scrollPosition)
        )
        NotificationCenter.default.post(name: .historySet, object: (chapterId, progress))
        if !completed && updateTrackers {
            Task {
                // update page trackers with progress
                await TrackerManager.shared.setProgress(
                    mangaId: mangaId,
                    chapter: chapter,
                    progress: .init(completed: false, page: progress)
                )
            }
        }
    }

    struct ReadingSessionData: Sendable {
        let startDate: Date
        let endDate: Date
        let pagesRead: Int
    }

    func addSession(chapterId: ChapterIdentifier, data: ReadingSessionData) async {
        await DataRepositories.shared.sessions.add(data, chapter: chapterId)
    }

    func addHistory(
        mangaId: MangaIdentifier,
        chapters: [AidokuRunner.Chapter],
        date: Date = Date(),
        skipTracker: Tracker? = nil,
        reason: String = "?"
    ) async {
        // mark the chapters and the manga as read
        let saved = await DataRepositories.shared.history.markCompleted(
            chapters.map { .init(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: $0.key) },
            date: date
        )
        // only what was saved goes in the journal (SUWA-12 H3): every chapter received, as before
        if saved == true {
            for chapter in chapters {
                CompletionJournal.record(
                    .init(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: chapter.key),
                    reason: reason
                )
            }
        }
        // nothing new: nothing else happens. A failed save (nil) still notifies and updates the trackers, as it did
        // before (the result of marking was what counted, not the save)
        guard saved != false else { return }
        NotificationCenter.default.post(
            name: .historyAdded,
            object: chapters.map {
                ChapterIdentifier(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: $0.key)
            }
        )
        // «descarga adelantada»: the window moves once the history is saved (reader or marked as read)
        Task {
            await DownloadManager.shared.ensureAheadDownloaded(mangaId: mangaId)
        }
        Task {
            if AppSettings.tracking.updateAfterReading.get() {
                // update tracker with chapter with largest number
                if let maxChapter = chapters.max(by: { $0.chapterNumber ?? 0 < $1.chapterNumber ?? 0 }) {
                    await TrackerManager.shared.setCompleted(
                        mangaId: mangaId,
                        chapter: maxChapter,
                        skipTracker: skipTracker
                    )
                }
            }

            await TrackerManager.shared.setProgress(
                mangaId: mangaId,
                chapters: chapters,
                progress: .init(completed: true, page: 0)
            )
        }
    }

    func removeHistory(chapterIds: [ChapterIdentifier]) async {
        guard !chapterIds.isEmpty else { return }
        await DataRepositories.shared.history.remove(chapters: chapterIds)
        NotificationCenter.default.post(name: .historyRemoved, object: chapterIds)
        Task {
            await TrackerManager.shared.setProgress(
                mangaId: chapterIds[0].mangaIdentifier,
                chapters: chapterIds.map { .init(key: $0.chapterKey) },
                progress: .init(completed: false, page: 0)
            )
        }
    }

    func removeHistory(mangaId: MangaIdentifier) async {
        await DataRepositories.shared.history.removeAll(of: mangaId)
        NotificationCenter.default.post(name: .historyRemoved, object: mangaId)
        Task {
            let chapters = await DataRepositories.shared.chapters.chapters(of: mangaId)
            await TrackerManager.shared.setProgress(
                mangaId: mangaId,
                chapters: chapters,
                progress: .init(completed: false, page: 0)
            )
        }
    }
}
