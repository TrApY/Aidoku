//
//  MigrationJournalTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L11a (D-L11-2): the completions of a migration go in the completion journal only once the migration
//  is saved; a saved migration writes the same lines as before (one per completed chapter, «migración desde <old>»).
//  The save is made to fail with a real conflict: while the migration's context is open (the tracker lookup runs
//  inside it), another context saves a change to the manga the migration is updating.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

/// The tracker lookup of a migration that, the first time it is asked, saves a change to `conflicting` from another
/// context, so that the migration's save (default merge policy) fails.
final class ConflictingLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    let tracker: Tracker
    let conflicting: MangaIdentifier

    init(tracker: Tracker, conflicting: MangaIdentifier) {
        self.tracker = tracker
        self.conflicting = conflicting
    }

    var fired: Bool { lock.withLock { done } }

    func lookup(_ id: String) -> Tracker? {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first {
            let context = CoreDataManager.shared.container.newBackgroundContext()
            let conflicting = conflicting
            context.performAndWait {
                CoreDataManager.shared.getManga(mangaId: conflicting, context: context)?.title = "conflicto"
                try? context.save()
            }
        }
        return id == tracker.id ? tracker : nil
    }
}

@Suite(.serialized) struct MigrationJournalTests {
    private let key = "contract.journal.\(UUID().uuidString)"
    private let fakeTracker = MigrationFakeTracker()

    private var old: AidokuRunner.Manga { AidokuRunner.Manga(sourceKey: "\(key).old", key: "1", title: "Viejo") }
    private var new: AidokuRunner.Manga { AidokuRunner.Manga(sourceKey: "\(key).new", key: "2", title: "Nuevo") }
    private var oldChapters: [AidokuRunner.Chapter] { (1...3).reversed().map { AidokuRunner.Chapter(key: "o\($0)", chapterNumber: Float($0)) } }
    private var newChapters: [AidokuRunner.Chapter] { (1...4).reversed().map { AidokuRunner.Chapter(key: "n\($0)", chapterNumber: Float($0)) } }

    /// The old manga in the library with chapters 1 and 2 read, chapter 3 at page 2 and a track.
    private func setUp() async {
        let oldId = old.identifier
        await MangaManager.shared.addToLibrary(manga: old, chapters: oldChapters, bindTrackers: false)
        await DataRepositories.shared.history.markCompleted(
            ["o1", "o2"].map { ChapterIdentifier(sourceKey: oldId.sourceKey, mangaKey: oldId.mangaKey, chapterKey: $0) },
            date: Date(timeIntervalSince1970: 1_790_000_000)
        )
        await DataRepositories.shared.history.savePage(
            PageSave(chapter: ChapterIdentifier(sourceKey: oldId.sourceKey, mangaKey: oldId.mangaKey, chapterKey: "o3"), page: 2)
        )
        await DataRepositories.shared.tracks.add(TrackItem(id: "track-\(key)", trackerId: fakeTracker.id, mangaId: oldId, title: "Viejo", chapterOffset: 0))
    }

    private func cleanUp() async {
        for id in [old.identifier, new.identifier] {
            await MangaManager.shared.removeFromLibrary(mangaId: id)
            await DataRepositories.shared.history.removeAll(of: id)
            await DataRepositories.shared.tracks.remove(trackerId: fakeTracker.id, manga: id)
        }
    }

    /// The journal lines of the new manga: [chapter key, reason, detail].
    private func journal() -> [[String]] {
        let prefix = "\t\(new.sourceKey)\t\(new.key)\t"
        return CompletionJournal.lines()
            .filter { $0.contains(prefix) }
            .map { Array($0.split(separator: "\t", omittingEmptySubsequences: false).dropFirst(3).map(String.init)) }
    }

    @Test func aMigrationThatIsNotSavedWritesNoJournal() async throws {
        await setUp()
        let conflict = ConflictingLookup(tracker: fakeTracker, conflicting: old.identifier)
        let environment = MigrationEnvironment(
            trackerLookup: { conflict.lookup($0) },
            suwayomiTracker: nil,
            deleteDownloads: { _ in },
            bindEnhancedTrackers: false
        )
        let result = await MangaManager.migrate(options: MigrationOptions(), from: old, to: new, withChapters: newChapters, environment: environment)
        #expect(conflict.fired) // the conflict was made inside the migration
        #expect(result == nil) // and the save failed
        #expect(journal() == [])
        await cleanUp()
    }

    @Test func aSavedMigrationWritesTheSameLinesAsBefore() async throws {
        await setUp()
        let fakeTracker = fakeTracker
        let environment = MigrationEnvironment(
            trackerLookup: { $0 == fakeTracker.id ? fakeTracker : nil },
            suwayomiTracker: nil,
            deleteDownloads: { _ in },
            bindEnhancedTrackers: false
        )
        let result = await MangaManager.migrate(options: MigrationOptions(), from: old, to: new, withChapters: newChapters, environment: environment)
        #expect(result != nil)
        let reason = "migración desde \(old.identifier)"
        // one line per completed chapter, in the order of the new chapters (as before)
        #expect(journal() == [["n2", reason, ""], ["n1", reason, ""]])
        // without read chapters, nothing
        await cleanUp()
        await setUp()
        let other = await MangaManager.migrate(
            options: MigrationOptions(readChapters: false), from: old, to: new, withChapters: newChapters, environment: environment
        )
        #expect(other != nil)
        #expect(journal().count == 2) // the two lines of the first migration only
        await cleanUp()
    }
}
