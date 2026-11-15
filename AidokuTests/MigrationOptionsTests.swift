//
//  MigrationOptionsTests.swift
//  AidokuTests
//
//  The migration sheet's choices and what each one does to the new entry (on the test host's Core Data,
//  with own source keys, removed at the end).
//

import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

struct MigrationOptionsTests {
    @Test func defaultsAreEverythingAndReplaceDeletingDownloads() {
        let options = MigrationOptions()
        #expect(options.readChapters && options.categories && options.tracking)
        #expect(!options.keepOriginal)
        #expect(options.deleteDownloads)
    }

    @Test func theLastChoiceIsRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "MigrationOptionsTests"))
        defer { defaults.removePersistentDomain(forName: "MigrationOptionsTests") }
        #expect(MigrationOptions.load(from: defaults) == MigrationOptions())
        let chosen = MigrationOptions(readChapters: true, categories: false, tracking: false, keepOriginal: true, deleteDownloads: false)
        chosen.save(to: defaults)
        #expect(MigrationOptions.load(from: defaults) == chosen)
        // something unreadable: the defaults
        defaults.set(Data("x".utf8), forKey: MigrationOptions.defaultsKey)
        #expect(MigrationOptions.load(from: defaults) == MigrationOptions())
    }

    @Test func theOldChoicesMapToOptions() {
        #expect(MigrationOptions(copy: true, forceRemoveFromLibrary: false).keepOriginal)
        #expect(!MigrationOptions(copy: false, forceRemoveFromLibrary: false).keepOriginal)
        #expect(!MigrationOptions(copy: true, forceRemoveFromLibrary: true).keepOriginal) // «migrate and keep history»
        let old = MigrationOptions(copy: false, forceRemoveFromLibrary: false)
        #expect(old.readChapters && old.categories && old.tracking && !old.deleteDownloads)
    }

    @Test func downloadsAreDeletedOnlyAfterASuccessfulMigration() {
        let old = MangaIdentifier(sourceKey: "a", mangaKey: "1")
        let new = MangaIdentifier(sourceKey: "b", mangaKey: "2")
        let options = MigrationOptions()
        #expect(options.shouldDeleteDownloads(old: old, new: new, succeeded: true))
        #expect(!options.shouldDeleteDownloads(old: old, new: new, succeeded: false))
        #expect(!options.shouldDeleteDownloads(old: old, new: old, succeeded: true)) // same entry: they're its own
        #expect(!MigrationOptions(deleteDownloads: false).shouldDeleteDownloads(old: old, new: new, succeeded: true))
        // keeping the original also allows it (the notice says so)
        #expect(MigrationOptions(keepOriginal: true).shouldDeleteDownloads(old: old, new: new, succeeded: true))
    }

    @Test func theNoticeFollowsTheChoices() {
        #expect(MigrationOptions().noteKeys(count: 1) == ["MIGRATION_NOTE_REPLACE_DELETE"])
        #expect(MigrationOptions(deleteDownloads: false).noteKeys(count: 1) == ["MIGRATION_NOTE_REPLACE_KEEP_DOWNLOADS"])
        #expect(MigrationOptions(keepOriginal: true, deleteDownloads: false).noteKeys(count: 1) == ["MIGRATION_NOTE_KEEP"])
        #expect(MigrationOptions(keepOriginal: true).noteKeys(count: 1) == ["MIGRATION_NOTE_KEEP_DELETE"])
        #expect(MigrationOptions().noteKeys(count: 3) == ["MIGRATION_NOTE_REPLACE_DELETE_MANY"])
        // replacing without the read chapters loses the reading history
        #expect(MigrationOptions(readChapters: false).noteKeys(count: 1) == ["MIGRATION_NOTE_REPLACE_DELETE", "MIGRATION_NOTE_HISTORY_LOST"])
        #expect(MigrationOptions(readChapters: false, keepOriginal: true).noteKeys(count: 2) == ["MIGRATION_NOTE_KEEP_DELETE_MANY"])
        // every key has a text in Spanish and English
        let keys = Set([MigrationOptions(), MigrationOptions(deleteDownloads: false), MigrationOptions(keepOriginal: true),
                        MigrationOptions(keepOriginal: true, deleteDownloads: false), MigrationOptions(readChapters: false)]
            .flatMap { $0.noteKeys(count: 1) + $0.noteKeys(count: 2) })
        for lang in ["es", "en"] {
            let bundle = Bundle(path: Bundle.main.path(forResource: lang, ofType: "lproj") ?? "")
            for key in keys {
                #expect(bundle?.localizedString(forKey: key, value: "·", table: nil) != "·", "\(lang): \(key)")
            }
        }
    }
}

/// A tracker of the user's (AniList-like) that can track anything.
final class MigrationFakeTracker: Tracker, @unchecked Sendable {
    let id = "migrationfaketracker"
    let name = "Fake"
    let icon: PlatformImage? = nil
    let isLoggedIn = true
    func getTrackerInfo() async throws -> TrackerInfo { .init(supportedStatuses: [], scoreType: .tenPoint, scoreOptions: []) }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { .init() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}

/// Records the downloads deleted.
final class DeletedDownloads: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MangaIdentifier] = []
    var ids: [MangaIdentifier] { lock.withLock { stored } }
    func add(_ id: MangaIdentifier) { lock.withLock { stored.append(id) } }
}

@Suite(.serialized) struct MigrationEffectsTests {
    private let oldSource = "migrationtest-old"
    private let newSource = "migrationtest-new"
    private let category = "MigrationTest"
    private let fakeTracker = MigrationFakeTracker()
    private let deleted = DeletedDownloads()

    private var old: AidokuRunner.Manga { .init(sourceKey: oldSource, key: "1", title: "Viejo") }
    private var new: AidokuRunner.Manga { .init(sourceKey: newSource, key: "2", title: "Nuevo") }
    private var oldChapters: [AidokuRunner.Chapter] { (1...3).reversed().map { .init(key: "o\($0)", chapterNumber: Float($0)) } }
    private var newChapters: [AidokuRunner.Chapter] { (1...4).reversed().map { .init(key: "n\($0)", chapterNumber: Float($0)) } }

    private var environment: MigrationEnvironment {
        let fakeTracker = fakeTracker
        let deleted = deleted
        return .init(
            trackerLookup: { $0 == fakeTracker.id ? fakeTracker : nil },
            suwayomiTracker: nil,
            deleteDownloads: { deleted.add($0) },
            bindEnhancedTrackers: false
        )
    }

    /// The old entry in the library with chapter 1 read, chapter 2 at page 4, a category and a track item.
    private func setUp() async {
        await cleanUp()
        await MangaManager.shared.addToLibrary(manga: old, chapters: oldChapters, bindTrackers: false)
        let oldId = old.identifier
        let category = category
        let trackerId = fakeTracker.id
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.setCompleted(chapterIds: [.init(sourceKey: oldId.sourceKey, mangaKey: oldId.mangaKey, chapterKey: "o1")], context: context)
            CoreDataManager.shared.setProgress(4, chapterId: .init(sourceKey: oldId.sourceKey, mangaKey: oldId.mangaKey, chapterKey: "o2"), totalPages: 20, context: context)
            _ = CoreDataManager.shared.createCategory(title: category, context: context)
            CoreDataManager.shared.addCategoriesToManga(mangaId: oldId, categories: [category], context: context)
            CoreDataManager.shared.createTrack(id: "track-1", trackerId: trackerId, mangaId: oldId, title: "Viejo", context: context)
            try? context.save()
        }
    }

    private func cleanUp() async {
        for id in [old.identifier, new.identifier] {
            await MangaManager.shared.removeFromLibrary(mangaId: id)
            await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.removeHistory(mangaId: id, context: context)
                try? context.save()
            }
        }
        let category = category
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeCategory(title: category, context: context)
            try? context.save()
        }
    }

    private struct State {
        var inLibrary: Bool
        var history: [String: Int]
        var categories: [String]
        var tracks: [String]
    }

    private func state(_ id: MangaIdentifier) async -> State {
        let history = await CoreDataManager.shared.getReadingHistory(mangaId: id).mapValues(\.page)
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            State(
                inLibrary: CoreDataManager.shared.hasLibraryManga(mangaId: id, context: context),
                history: history,
                categories: CoreDataManager.shared.getCategories(mangaId: id, context: context).compactMap(\.title),
                tracks: CoreDataManager.shared.getTracks(mangaId: id, context: context).compactMap(\.id)
            )
        }
    }

    private func migrate(_ options: MigrationOptions) async -> Bool {
        await MangaManager.migrate(options: options, from: old, to: new, withChapters: newChapters, environment: environment) != nil
    }

    @Test func replacingWithEverything() async {
        await setUp()
        #expect(await migrate(MigrationOptions()))
        let newState = await state(new.identifier)
        #expect(newState.inLibrary)
        #expect(newState.history == ["n1": -1, "n2": 4])
        #expect(newState.categories == [category])
        #expect(newState.tracks == ["track-1"])
        #expect(!(await state(old.identifier).inLibrary))
        #expect(deleted.ids == [old.identifier])
        await cleanUp()
    }

    @Test func withoutReadChapters() async {
        await setUp()
        #expect(await migrate(MigrationOptions(readChapters: false)))
        let newState = await state(new.identifier)
        #expect(newState.history.isEmpty) // neither read nor half-read
        #expect(newState.categories == [category])
        #expect(newState.tracks == ["track-1"])
        await cleanUp()
    }

    @Test func withoutCategories() async {
        await setUp()
        #expect(await migrate(MigrationOptions(categories: false)))
        #expect(await state(new.identifier).categories.isEmpty) // also when the old object is reused
        await cleanUp()
        await setUp()
        #expect(await migrate(MigrationOptions(categories: false, keepOriginal: true)))
        #expect(await state(new.identifier).categories.isEmpty)
        #expect(await state(old.identifier).categories == [category])
        await cleanUp()
    }

    @Test func withoutTracking() async {
        await setUp()
        #expect(await migrate(MigrationOptions(tracking: false)))
        #expect(await state(new.identifier).tracks.isEmpty)
        await cleanUp()
        await setUp()
        #expect(await migrate(MigrationOptions(tracking: false, keepOriginal: true)))
        #expect(await state(new.identifier).tracks.isEmpty)
        #expect(await state(old.identifier).tracks == ["track-1"])
        await cleanUp()
    }

    @Test func keepingTheOriginal() async {
        await setUp()
        #expect(await migrate(MigrationOptions(keepOriginal: true, deleteDownloads: false)))
        let oldState = await state(old.identifier)
        #expect(oldState.inLibrary)
        #expect(oldState.history == ["o1": -1, "o2": 4]) // as it was
        let newState = await state(new.identifier)
        #expect(newState.inLibrary)
        #expect(newState.history == ["n1": -1, "n2": 4])
        #expect(newState.categories == [category])
        #expect(newState.tracks == ["track-1"])
        #expect(deleted.ids.isEmpty)
        await cleanUp()
    }

    @Test func noDownloadIsDeletedWhenTheMigrationFails() async {
        await setUp()
        // the destination's source isn't there: nothing is migrated, nothing deleted
        await MangaManager.shared.migrate(
            options: MigrationOptions(),
            fromSeries: [old],
            toSeries: [old.identifier: AidokuRunner.Manga(sourceKey: "migrationtest-nosource", key: "9", title: "X")],
            environment: environment
        )
        #expect(deleted.ids.isEmpty)
        #expect(await state(old.identifier).inLibrary)
        // the option off: kept
        #expect(await migrate(MigrationOptions(deleteDownloads: false)))
        #expect(deleted.ids.isEmpty)
        await cleanUp()
    }
}

@Suite(.serialized) struct SuwayomiMigrationOptionsTests {
    private let key = "suwayomi.migrationtest"
    private let server = SuwayomiFakeServer()

    private var old: AidokuRunner.Manga { .init(sourceKey: key, key: "753", title: "Viejo") }
    private var new: AidokuRunner.Manga { .init(sourceKey: key, key: "897", title: "Nuevo") }
    private var chapters: [AidokuRunner.Chapter] { (1...3).reversed().map { .init(key: "c\($0)", chapterNumber: Float($0)) } }

    private func run(_ options: MigrationOptions) async {
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(key).server")
        server.respond("GetInLibrary", .success(Data(#"{"data":{"manga":{"inLibrary":false}}}"#.utf8)))
        server.respond("AddToServerLibrary", .success(Data(#"{"data":{"updateManga":{"manga":{"id":897,"inLibrary":true}}}}"#.utf8)))
        server.respond("GetTrackState", .success(Data(#"{"data":{"manga":{"chapters":{"totalCount":3},"latestReadChapter":null,"highestNumberedChapter":{"chapterNumber":3}}}}"#.utf8)))
        server.respond("GetChaptersForTrackUpdate", .success(Data(#"{"data":{"chapters":{"nodes":[{"id":11,"chapterNumber":1}]}}}"#.utf8)))
        server.respond("MarkChaptersRead", .success(Data(#"{"data":{"updateChapters":{"chapters":[]}}}"#.utf8)))
        server.respond("RemoveFromServerLibrary", .success(Data(#"{"data":{"updateManga":{"manga":{"id":753,"inLibrary":false}}}}"#.utf8)))
        let old = old
        await MangaManager.shared.addToLibrary(manga: old, chapters: chapters, bindTrackers: false)
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.setCompleted(chapterIds: [.init(sourceKey: old.sourceKey, mangaKey: old.key, chapterKey: "c1")], context: context)
            CoreDataManager.shared.createTrack(id: "\(old.sourceKey)|753", trackerId: "suwayomi", mangaId: old.identifier, title: nil, context: context)
            try? context.save()
        }
        let environment = MigrationEnvironment(
            trackerLookup: { _ in nil },
            suwayomiTracker: SuwayomiTracker(api: SuwayomiApi(transport: server.transport)),
            deleteDownloads: { _ in },
            bindEnhancedTrackers: false
        )
        let newChapters: [AidokuRunner.Chapter] = (1...3).reversed().map { .init(key: "d\($0)", chapterNumber: Float($0)) }
        _ = await MangaManager.migrate(options: options, from: old, to: new, withChapters: newChapters, environment: environment)
    }

    private func cleanUp() async {
        for id in [old.identifier, new.identifier] {
            await MangaManager.shared.removeFromLibrary(mangaId: id)
            await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.removeHistory(mangaId: id, context: context)
                try? context.save()
            }
        }
        UserDefaults.standard.removeObject(forKey: "\(key).server")
    }

    @Test func withoutReadChaptersTheServerGetsNoMarks() async {
        await run(MigrationOptions(readChapters: false))
        #expect(server.variables("AddToServerLibrary").map { $0["id"] as? Int } == [897]) // still in the server library
        #expect(server.count("GetChaptersForTrackUpdate") == 0)
        #expect(server.count("MarkChaptersRead") == 0)
        #expect(server.variables("RemoveFromServerLibrary").map { $0["id"] as? Int } == [753])
        await cleanUp()
    }

    @Test func withoutTrackingTheServerTrackerStillRegisters() async {
        await run(MigrationOptions(tracking: false))
        #expect(server.variables("AddToServerLibrary").map { $0["id"] as? Int } == [897])
        #expect(server.count("MarkChaptersRead") == 1)
        let tracks = await CoreDataManager.shared.container.performBackgroundTask { [new] context in
            CoreDataManager.shared.getTracks(mangaId: new.identifier, context: context).compactMap(\.id)
        }
        #expect(tracks == ["\(key)|897"])
        await cleanUp()
    }

    @Test func keepingTheOriginalKeepsItOnTheServer() async {
        await run(MigrationOptions(keepOriginal: true))
        #expect(server.variables("AddToServerLibrary").map { $0["id"] as? Int } == [897])
        #expect(server.count("RemoveFromServerLibrary") == 0)
        await cleanUp()
    }
}
