//
//  RepositoryFixture.swift
//  AidokuTests
//
//  SUWA-13 F4: the contract tests run against every fixture (Core Data now; SwiftData in F19), each test on a
//  store of its own that is removed at the end. Never the app's store.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

/// A store with its repositories, and how to remove it.
struct FixtureStore: Sendable {
    let repos: DataRepositories
    /// Puts these manga in the library (no chapters) and takes them out, until the library has its writes (L7).
    let addToLibrary: @Sendable ([MangaIdentifier]) async -> Void
    let removeFromLibrary: @Sendable ([MangaIdentifier]) async -> Void
    /// Puts stored chapters and history rows in the store, as they can be found there, until history has its
    /// writes (L5) and chapters theirs (L6).
    let seed: any FixtureSeeder
    /// The same store opened read-only: every save of these repositories fails (to check that a failed write
    /// leaves nothing half done).
    let failingRepos: DataRepositories
    let tearDown: @Sendable () async -> Void
}

protocol RepositoryFixture: Sendable, CustomTestStringConvertible {
    func make() async throws -> FixtureStore
}

/// A history row as it can be found in a store (not necessarily as the app writes it).
struct HistorySeed: Sendable {
    var chapter: ChapterIdentifier
    /// nil: as a new row starts (-1)
    var progress: Int?
    /// nil: as a new row starts (0)
    var total: Int?
    var completed = false
    /// a new row starts at .distantPast (the model requires a date: nil does not save)
    var dateRead: Date? = .distantPast
    var scrollPosition: Double?
    /// linked to its stored chapter (if there is one)
    var linked = true
}

/// Fields of a stored manga (not in the library).
struct MangaSeed: Sendable {
    var flags = 0
    var language: String?
    var scanlators: [String]?
    var viewer = 0
    var cover: String?
    /// nil: keep it (a new manga is titled with its key)
    var title: String?
    var author: String?
    var url: String?
    var status = 0
    var nsfw = 0
}

/// The dates of a library entry.
struct LibraryDatesSeed: Sendable {
    var dateAdded: Date
    var lastOpened: Date
    var lastUpdated: Date
    var lastUpdatedChapters: Date
    var lastChapter: Date?
    var lastRead: Date?
}

protocol FixtureSeeder: Sendable {
    /// Stores these chapters of the manga in this order (source order 0, 1…), creating the manga (not in the
    /// library) if it is not stored.
    func addChapters(_ chapters: [AidokuRunner.Chapter], to manga: MangaIdentifier) async
    /// Adds a history row, without looking for one of the same chapter.
    func addHistory(_ seed: HistorySeed) async
    func historyRows(of chapter: ChapterIdentifier) async -> Int
    func isLinked(_ chapter: ChapterIdentifier) async -> Bool
    /// The library entry's last read date (nil: not in the library). A new entry starts with «now».
    func lastRead(of manga: MangaIdentifier) async -> Date?
    func setLastRead(_ date: Date, of manga: MangaIdentifier) async
    /// Reading sessions of the chapter's history rows.
    func sessions(of chapter: ChapterIdentifier) async -> [HistoryManager.ReadingSessionData]
    /// Stores the manga (not in the library) if it is not stored, and sets these fields.
    func setManga(_ manga: MangaIdentifier, _ fields: MangaSeed) async
    /// Sets the dates of the manga's library entry (the first one, if there are several).
    func setLibraryDates(_ manga: MangaIdentifier, _ dates: LibraryDatesSeed) async
    /// Another stored manga with the same identifier, in the library too (as a sync can leave them).
    func addDuplicateLibraryEntry(_ manga: MangaIdentifier) async
    /// A library entry without a manga.
    func addLibraryEntryWithoutManga() async
    /// The dates of the manga's library entry (the first one); nil if it is not in the library.
    func libraryDates(of manga: MangaIdentifier) async -> LibraryDatesSeed?
    /// The manga's update rows (chapter key and whether it was viewed), in no particular order.
    func updates(of manga: MangaIdentifier) async -> [String: Bool]
    /// The store the sources are saved in (their entity is in the local configuration).
    func sourceStore(key: String) async -> String?
    /// Right before the next save of another context of this store, moves the category `title` to `position` and
    /// saves it from a context of its own: a concurrent write that next save meets (D-L12-9).
    func moveCategoryBeforeNextSave(_ title: String, to position: Int) async
}

struct CoreDataSeeder: FixtureSeeder, @unchecked Sendable {
    let container: NSPersistentContainer

    func addChapters(_ chapters: [AidokuRunner.Chapter], to manga: MangaIdentifier) async {
        await container.performBackgroundTask { context in
            let object = CoreDataManager.shared.getOrCreateManga(
                AidokuRunner.Manga(sourceKey: manga.sourceKey, key: manga.mangaKey, title: manga.mangaKey),
                context: context
            )
            for (index, chapter) in chapters.enumerated() {
                CoreDataManager.shared.createChapter(chapter, mangaId: manga, sourceOrder: index, mangaObject: object, context: context)
            }
            try? context.save()
        }
    }

    func addHistory(_ seed: HistorySeed) async {
        await container.performBackgroundTask { context in
            let history = HistoryObject(context: context)
            history.sourceId = seed.chapter.sourceKey
            history.mangaId = seed.chapter.mangaKey
            history.chapterId = seed.chapter.chapterKey
            if let progress = seed.progress { history.progress = Int16(progress) }
            if let total = seed.total { history.total = Int16(total) }
            history.completed = seed.completed
            history.dateRead = seed.dateRead
            history.scrollPosition = seed.scrollPosition.map { NSNumber(value: $0) }
            if seed.linked {
                history.chapter = CoreDataManager.shared.getChapter(chapterId: seed.chapter, context: context)
            }
            do {
                try context.save()
            } catch {
                Issue.record("the seed was not saved: \(error)")
                context.rollback()
            }
        }
    }

    private func rows(_ chapter: ChapterIdentifier, _ context: NSManagedObjectContext) -> [HistoryObject] {
        let request = HistoryObject.fetchRequest()
        request.predicate = NSPredicate(
            format: "chapterId == %@ AND mangaId == %@ AND sourceId == %@",
            chapter.chapterKey, chapter.mangaKey, chapter.sourceKey
        )
        return (try? context.fetch(request)) ?? []
    }

    func historyRows(of chapter: ChapterIdentifier) async -> Int {
        await container.performBackgroundTask { context in rows(chapter, context).count }
    }

    func isLinked(_ chapter: ChapterIdentifier) async -> Bool {
        await container.performBackgroundTask { context in rows(chapter, context).contains { $0.chapter != nil } }
    }

    func lastRead(of manga: MangaIdentifier) async -> Date? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(mangaId: manga, context: context)?.lastRead
        }
    }

    func setLastRead(_ date: Date, of manga: MangaIdentifier) async {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(mangaId: manga, context: context)?.lastRead = date
            try? context.save()
        }
    }

    func sessions(of chapter: ChapterIdentifier) async -> [HistoryManager.ReadingSessionData] {
        await container.performBackgroundTask { context in
            rows(chapter, context)
                .flatMap { ($0.sessions as? Set<ReadingSessionObject>) ?? [] }
                .map { .init(startDate: $0.startDate ?? .distantPast, endDate: $0.endDate ?? .distantPast, pagesRead: Int($0.pagesRead)) }
                .sorted { $0.startDate < $1.startDate }
        }
    }

    private func saveSeed(_ context: NSManagedObjectContext) {
        do {
            try context.save()
        } catch {
            Issue.record("the seed was not saved: \(error)")
            context.rollback()
        }
    }

    func setLibraryDates(_ manga: MangaIdentifier, _ dates: LibraryDatesSeed) async {
        await container.performBackgroundTask { context in
            guard let entry = CoreDataManager.shared.getLibraryManga(mangaId: manga, context: context) else {
                Issue.record("not in the library: \(manga)")
                return
            }
            entry.dateAdded = dates.dateAdded
            entry.lastOpened = dates.lastOpened
            entry.lastUpdated = dates.lastUpdated
            entry.lastUpdatedChapters = dates.lastUpdatedChapters
            entry.lastChapter = dates.lastChapter
            entry.lastRead = dates.lastRead
            saveSeed(context)
        }
    }

    func addDuplicateLibraryEntry(_ manga: MangaIdentifier) async {
        await container.performBackgroundTask { context in
            let object = CoreDataManager.shared.createManga(
                AidokuRunner.Manga(sourceKey: manga.sourceKey, key: manga.mangaKey, title: manga.mangaKey),
                context: context
            )
            let entry = LibraryMangaObject(context: context)
            entry.manga = object
            saveSeed(context)
        }
    }

    func libraryDates(of manga: MangaIdentifier) async -> LibraryDatesSeed? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(mangaId: manga, context: context).map {
                LibraryDatesSeed(
                    dateAdded: $0.dateAdded,
                    lastOpened: $0.lastOpened,
                    lastUpdated: $0.lastUpdated,
                    lastUpdatedChapters: $0.lastUpdatedChapters,
                    lastChapter: $0.lastChapter,
                    lastRead: $0.lastRead
                )
            }
        }
    }

    func updates(of manga: MangaIdentifier) async -> [String: Bool] {
        await container.performBackgroundTask { context in
            let request = MangaUpdateObject.fetchRequest()
            request.predicate = NSPredicate(format: "sourceId == %@ AND mangaId == %@", manga.sourceKey, manga.mangaKey)
            var rows: [String: Bool] = [:]
            for row in (try? context.fetch(request)) ?? [] {
                rows[row.chapterId ?? ""] = row.viewed
            }
            return rows
        }
    }

    func sourceStore(key: String) async -> String? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getSource(key: key, context: context)?.objectID.persistentStore?.configurationName
        }
    }

    func moveCategoryBeforeNextSave(_ title: String, to position: Int) async {
        let coordinator = container.persistentStoreCoordinator
        let other = container.newBackgroundContext()
        let observer = OneShotObserver()
        observer.token = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextWillSave,
            object: nil,
            queue: nil
        ) { note in
            guard
                let saving = note.object as? NSManagedObjectContext,
                saving !== other,
                saving.persistentStoreCoordinator === coordinator,
                observer.fire()
            else { return }
            other.performAndWait {
                CoreDataManager.shared.moveCategory(title: title, toPosition: position, context: other)
                do {
                    try other.save()
                } catch {
                    Issue.record("the concurrent move was not saved: \(error)")
                }
            }
        }
    }

    func addLibraryEntryWithoutManga() async {
        await container.performBackgroundTask { context in
            _ = LibraryMangaObject(context: context)
            saveSeed(context)
        }
    }

    func setManga(_ manga: MangaIdentifier, _ fields: MangaSeed) async {
        await container.performBackgroundTask { context in
            let object = CoreDataManager.shared.getOrCreateManga(
                AidokuRunner.Manga(sourceKey: manga.sourceKey, key: manga.mangaKey, title: manga.mangaKey),
                context: context
            )
            object.chapterFlags = Int16(fields.flags)
            object.langFilter = fields.language
            object.scanlatorFilter = fields.scanlators
            object.viewer = Int16(fields.viewer)
            object.cover = fields.cover
            if let title = fields.title {
                object.title = title
            }
            object.author = fields.author
            object.url = fields.url
            object.status = Int16(fields.status)
            object.nsfw = Int16(fields.nsfw)
            do {
                try context.save()
            } catch {
                Issue.record("the seed was not saved: \(error)")
                context.rollback()
            }
        }
    }
}

/// An observer that acts once and then stops observing.
final class OneShotObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var token: NSObjectProtocol?

    /// true the first time only (and it stops observing).
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        return true
    }
}

/// Every fixture the contract tests run against.
let repositoryFixtures: [any RepositoryFixture] = [CoreDataFixture()]

/// A Core Data store in a temporary folder (the pattern of ConversionStore): the app's model and its Cloud and
/// Local configurations, persistent history on, synchronous loading. The model is the app's own instance
/// (`CoreDataManager.shared.container.managedObjectModel`): the test host app already loads its store at launch
/// (AppDelegate), and a second model instance would make the entity classes (TrackObject…) ambiguous.
struct CoreDataFixture: RepositoryFixture {
    var testDescription: String { "Core Data" }

    func make() async throws -> FixtureStore {
        let store = try Self.container()
        let repos = DataRepositories(container: store.container)
        let container = store.container
        let readOnly = try Self.container(in: store.directory, readOnly: true)
        return FixtureStore(
            repos: repos,
            addToLibrary: { ids in
                await container.performBackgroundTask { context in
                    for id in ids {
                        let manga = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: id.mangaKey)
                        CoreDataManager.shared.addToLibrary(manga: manga, chapters: [], context: context)
                    }
                    try? context.save()
                }
            },
            removeFromLibrary: { ids in
                await container.performBackgroundTask { context in
                    CoreDataManager.shared.removeFromLibrary(ids: ids, context: context)
                    try? context.save()
                }
            },
            seed: CoreDataSeeder(container: container),
            failingRepos: DataRepositories(container: readOnly.container),
            tearDown: {
                Self.remove(readOnly.container, directory: nil)
                Self.remove(store.container, directory: store.directory)
            }
        )
    }

    static func container(in existing: URL? = nil, readOnly: Bool = false) throws -> (container: NSPersistentContainer, directory: URL) {
        let directory = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = NSPersistentContainer(name: "Aidoku", managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        let cloud = NSPersistentStoreDescription(url: directory.appendingPathComponent("Aidoku.sqlite"))
        cloud.configuration = "Cloud"
        cloud.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloud.shouldAddStoreAsynchronously = false
        let local = NSPersistentStoreDescription(url: directory.appendingPathComponent("Local.sqlite"))
        local.configuration = "Local"
        local.shouldAddStoreAsynchronously = false
        cloud.isReadOnly = readOnly
        local.isReadOnly = readOnly
        container.persistentStoreDescriptions = [cloud, local]
        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error { loadError = error }
        }
        if let loadError { throw loadError }
        return (container, directory)
    }

    static func remove(_ container: NSPersistentContainer, directory: URL?) {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

@Suite struct RepositoryFixtureTests {
    /// The fixture's store is its own folder, never the app's, and it is gone after tearDown.
    @Test func theCoreDataFixtureIsIsolated() async throws {
        let store = try CoreDataFixture.container()
        let urls = store.container.persistentStoreCoordinator.persistentStores.compactMap(\.url)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.path.hasPrefix(store.directory.path) })
        let app = CoreDataManager.shared.container.persistentStoreCoordinator.persistentStores.compactMap(\.url)
        #expect(Set(urls).isDisjoint(with: app))
        CoreDataFixture.remove(store.container, directory: store.directory)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }
}
