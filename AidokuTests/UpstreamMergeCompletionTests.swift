//
//  UpstreamMergeCompletionTests.swift
//  AidokuTests
//
//  SUWA-18 C1: two upstream fixes the merge did not take because the fork already did them its own way, pinned
//  where they meet the completion journal (what RereadRule decides «being read again» from):
//  - 7a02c25f «only mark completed as read when migrating»: the fork's MigrationHistory.plan; only the completed
//    chapters are completed on the new entry and go in the journal; the unfinished one keeps its page.
//  - bac65cc1 «correctly mark previous ascending chapters»: the fork's previousChapters (source order); in
//    ascending order with a language filter, every chapter before goes in the journal, hidden ones too.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct UpstreamMergeCompletionTests {
    private static let chapters: [AidokuRunner.Chapter] = [
        .init(key: "c3", chapterNumber: 3), .init(key: "c2", chapterNumber: 2), .init(key: "c1", chapterNumber: 1)
    ]

    private func cleanUp(_ ids: [MangaIdentifier]) async {
        for id in ids {
            await MangaManager.shared.removeFromLibrary(mangaId: id)
            await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.removeHistory(mangaId: id, context: context)
                CoreDataManager.shared.removeManga(mangaId: id, context: context)
                try? context.save()
            }
        }
    }

    private func chapterId(_ manga: AidokuRunner.Manga, _ key: String) -> ChapterIdentifier {
        .init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: key)
    }

    /// Old: c1 completed, c2 at page 5 of 20. Migrated with «read chapters»: on the new one c1 is completed and in
    /// the journal; c2 is not completed, not in the journal, and keeps page 5.
    @Test func migratingCompletesAndJournalsOnlyTheCompletedChapters() async throws {
        let old = AidokuRunner.Manga(sourceKey: "s18migrar-vieja", key: "1", title: "Vieja")
        let new = AidokuRunner.Manga(sourceKey: "s18migrar-nueva", key: "2", title: "Nueva")
        await cleanUp([old.identifier, new.identifier])
        await MangaManager.shared.addToLibrary(manga: old, chapters: Self.chapters, bindTrackers: false)
        await DataRepositories.shared.history.markCompleted([chapterId(old, "c1")], date: Date(timeIntervalSinceNow: -86_400))
        await DataRepositories.shared.history.savePage(PageSave(chapter: chapterId(old, "c2"), page: 5, totalPages: 20))
        let options = MigrationOptions(readChapters: true, categories: false, tracking: false, keepOriginal: false, deleteDownloads: false)
        let environment = MigrationEnvironment(trackerLookup: { _ in nil }, suwayomiTracker: nil, deleteDownloads: { _ in }, bindEnhancedTrackers: false)
        _ = await MangaManager.migrate(options: options, from: old, to: new, withChapters: Self.chapters, environment: environment)

        let journal = CompletionJournal.latestCompletions()
        let first = await DataRepositories.shared.history.progress(of: chapterId(new, "c1"))
        let second = await DataRepositories.shared.history.progress(of: chapterId(new, "c2"))
        #expect(first.completed)
        #expect(journal.last(of: chapterId(new, "c1")) != nil, "c1 not in the journal")
        #expect(!second.completed, "the unfinished chapter was completed")
        #expect(second.progress == 5)
        #expect(journal.last(of: chapterId(new, "c2")) == nil, "the unfinished chapter is in the journal")
        await cleanUp([old.identifier, new.identifier])
    }

    /// Ascending order, only Spanish chapters shown: «mark previous» on c5 completes and journals c1…c4, the
    /// English ones hidden by the filter too, and nothing after c5.
    @MainActor
    @Test func markingPreviousInAscendingOrderJournalsEveryChapterBefore() async throws {
        var manga = AidokuRunner.Manga(sourceKey: "s18anteriores", key: "1", title: "Anteriores")
        var list: [AidokuRunner.Chapter] = []
        for number in (1...8).reversed() {
            list.append(AidokuRunner.Chapter(key: "c\(number)", chapterNumber: Float(number), language: number % 2 == 1 ? "es" : "en"))
        }
        manga.chapters = list
        await cleanUp([manga.identifier])
        let model = MangaView.ViewModel(source: nil, manga: manga)
        model.applyingStoredSort = true
        model.chapterSortAscending = true
        model.chapterLangFilter = "es"
        let chapter = try #require(list.first { $0.key == "c5" })
        await model.markRead(chapters: model.previousChapters(before: chapter))

        let journal = CompletionJournal.latestCompletions()
        for number in 1...4 {
            #expect(journal.last(of: chapterId(manga, "c\(number)")) != nil, "c\(number) not in the journal")
            #expect(await DataRepositories.shared.history.progress(of: chapterId(manga, "c\(number)")).completed, "c\(number)")
        }
        for number in 5...8 {
            #expect(journal.last(of: chapterId(manga, "c\(number)")) == nil, "c\(number) in the journal")
        }
        await cleanUp([manga.identifier])
    }
}
