//
//  MigrationContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L11a (D-L11-1..4): one entry of a manga migration, as LibraryRepository.migrate does it in one
//  context and one save, against every fixture: replacing (with a new manga out of the library or already in it),
//  keeping the original, with and without categories and read chapters, the unfinished chapter's page, the tracks,
//  a failed save and the notifications. The journal, the settings and the server work stay with MangaManager.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

/// The notifications of the app (the ones its services post) whose object mentions `key`, while it is alive. Those
/// without an object can't be told apart from other suites' and are not counted.
final class NotificationSpy: @unchecked Sendable {
    static let names: [Notification.Name] = [
        .migratedManga, .updateLibrary, .updateHistory, .historyAdded, .historySet, .historyRemoved, .addToLibrary,
        .removeFromLibrary, .updateTrackers, .trackItemAdded, .updateCategories, .updateMangaDetails,
    ]

    private let lock = NSLock()
    private var seen: [String] = []
    private var observers: [NSObjectProtocol] = []

    init(key: String) {
        observers = Self.names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let object = note.object, String(describing: object).contains(key) else { return }
                self?.lock.withLock { self?.seen.append(note.name.rawValue) }
            }
        }
    }

    var names: [String] { lock.withLock { seen } }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }
}

@Suite(.serialized) struct MigrationContractTests {
    private let key = "contract.\(UUID().uuidString)"
    private let tracker = "contract.tracker"

    private var oldId: MangaIdentifier { MangaIdentifier(sourceKey: "\(key).old", mangaKey: "1") }
    private var newId: MangaIdentifier { MangaIdentifier(sourceKey: "\(key).new", mangaKey: "2") }
    private var old: AidokuRunner.Manga { AidokuRunner.Manga(sourceKey: oldId.sourceKey, key: oldId.mangaKey, title: "Viejo") }
    private var new: AidokuRunner.Manga { AidokuRunner.Manga(sourceKey: newId.sourceKey, key: newId.mangaKey, title: "Nuevo") }
    private var oldChapters: [AidokuRunner.Chapter] { (1...3).reversed().map { AidokuRunner.Chapter(key: "o\($0)", chapterNumber: Float($0)) } }
    private var newChapters: [AidokuRunner.Chapter] { (1...4).reversed().map { AidokuRunner.Chapter(key: "n\($0)", chapterNumber: Float($0)) } }

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func chapter(_ manga: MangaIdentifier, _ chapterKey: String) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: chapterKey)
    }

    /// The old entry in the library: chapters o1-o3, o1 completed on day 1 (no total), o2 at page 4 of an unknown
    /// total (0) without a scroll position on day 2, the category «Antigua», a track, last read on day 5.
    private func seedOld(_ store: FixtureStore) async {
        let repos = store.repos
        await repos.categories.create(title: "Antigua")
        await repos.library.add(old, chapters: oldChapters, defaultCategory: nil, adoptChapterFlags: nil)
        await repos.categories.assign([oldId], add: ["Antigua"])
        await store.seed.addHistory(HistorySeed(chapter: chapter(oldId, "o1"), total: 0, completed: true, dateRead: day(1)))
        await store.seed.addHistory(HistorySeed(chapter: chapter(oldId, "o2"), progress: 4, total: 0, dateRead: day(2)))
        await store.seed.setLastRead(day(5), of: oldId)
        await repos.tracks.add(TrackItem(id: "t-1", trackerId: tracker, mangaId: oldId, title: "Viejo", chapterOffset: 0))
    }

    private func request(_ options: MigrationOptions, newWasInLibrary: Bool = false, canTrack: Bool = true) -> MigrationRequest {
        let tracker = tracker
        return MigrationRequest(
            options: options,
            old: old,
            new: new,
            newChapters: newChapters,
            newWasInLibrary: newWasInLibrary,
            suwayomiTrackerId: nil,
            suwayomiNewTrackId: nil,
            canTrackNew: { canTrack && $0 == tracker }
        )
    }

    /// Replacing with a manga out of the library: the old entry becomes the new one (its library entry, categories
    /// and last read date stay), its chapters and history go, the new chapters come with the history carried over
    /// (completed with the old date; the unfinished page without a total), and the track moves.
    @Test(arguments: repositoryFixtures)
    func replacingWithANewMangaOutOfTheLibrary(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedOld(store)
        let outcome = try #require(await repos.library.migrate(request(MigrationOptions())))
        #expect(outcome.from.key == "1" && outcome.to.key == "2")
        #expect(outcome.completions == [.init(chapter: chapter(newId, "n1"), reason: "migración desde \(oldId)")])
        #expect(await !repos.library.contains(oldId))
        #expect(await !repos.manga.contains(oldId))
        #expect(await repos.library.contains(newId))
        #expect(await repos.manga.manga(newId)?.title == "Nuevo")
        #expect(await repos.chapters.chapters(of: newId).map(\.key) == ["n4", "n3", "n2", "n1"])
        #expect(await repos.chapters.chapters(of: oldId).isEmpty)
        #expect(await repos.categories.categories(of: newId) == ["Antigua"])
        #expect(await store.seed.lastRead(of: newId) == day(5))
        let n1 = try #require(await repos.history.record(of: chapter(newId, "n1")))
        #expect(n1.completed && n1.dateRead == day(1))
        let n2 = try #require(await repos.history.record(of: chapter(newId, "n2")))
        #expect(!n2.completed && n2.progress == 4 && n2.total == 0 && n2.scrollPosition == nil && n2.dateRead == day(2))
        #expect(await repos.history.record(of: chapter(newId, "n3")) == nil)
        #expect(await repos.history.record(of: chapter(oldId, "o1")) == nil)
        #expect(await repos.history.record(of: chapter(oldId, "o2")) == nil)
        #expect(await repos.tracks.items(of: newId).map(\.id) == ["t-1"])
        #expect(await repos.tracks.items(of: oldId).isEmpty)
        await store.tearDown()
    }

    /// Without read chapters the entry's last read date goes and no history is carried over (the old one goes
    /// anyway); without categories the entry keeps none.
    @Test(arguments: repositoryFixtures)
    func replacingWithoutReadChaptersNorCategories(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedOld(store)
        let outcome = try #require(await repos.library.migrate(request(MigrationOptions(readChapters: false, categories: false))))
        #expect(outcome.completions.isEmpty)
        #expect(await repos.library.contains(newId))
        #expect(await store.seed.lastRead(of: newId) == nil)
        #expect(await repos.categories.categories(of: newId).isEmpty)
        #expect(await repos.history.readingHistory(of: newId).isEmpty)
        #expect(await repos.history.record(of: chapter(oldId, "o1")) == nil)
        await store.tearDown()
    }

    /// Replacing with a manga already in the library: the old one is removed, the new one gets the details and keeps
    /// its own categories (plus the old ones if asked), its own last read date and a page further on than the old one.
    @Test(arguments: repositoryFixtures)
    func replacingWithANewMangaAlreadyInTheLibrary(fixture: any RepositoryFixture) async throws {
        for categories in [true, false] {
            let store = try await fixture.make()
            let repos = store.repos
            await seedOld(store)
            await repos.categories.create(title: "Nueva")
            await repos.library.add(
                AidokuRunner.Manga(sourceKey: newId.sourceKey, key: newId.mangaKey, title: "Antes"),
                chapters: newChapters, defaultCategory: "Nueva", adoptChapterFlags: nil
            )
            await store.seed.setLastRead(day(9), of: newId)
            await store.seed.addHistory(HistorySeed(chapter: chapter(newId, "n2"), progress: 7, total: 20, dateRead: day(8)))
            let outcome = try #require(await repos.library.migrate(request(MigrationOptions(readChapters: true, categories: categories))))
            #expect(outcome.completions.map(\.chapter.chapterKey) == ["n1"])
            #expect(await !repos.library.contains(oldId))
            #expect(await !repos.manga.contains(oldId))
            #expect(await repos.manga.manga(newId)?.title == "Nuevo")
            #expect(Set(await repos.categories.categories(of: newId)) == (categories ? ["Antigua", "Nueva"] : ["Nueva"]))
            #expect(await store.seed.lastRead(of: newId) == day(9))
            let n2 = try #require(await repos.history.record(of: chapter(newId, "n2")))
            #expect(n2.progress == 7 && n2.total == 20 && n2.dateRead == day(8)) // not stepped on
            #expect(try #require(await repos.history.record(of: chapter(newId, "n1"))).completed)
            #expect(await repos.tracks.items(of: newId).map(\.id) == ["t-1"])
            await store.tearDown()
        }
    }

    /// Keeping the original (the service added the new one first, with the default category): the original stays as
    /// it was; the new one gets the history and a copy of the track, and the old categories, or none at all (not
    /// even the default one) without categories.
    @Test(arguments: repositoryFixtures)
    func keepingTheOriginal(fixture: any RepositoryFixture) async throws {
        for categories in [true, false] {
            let store = try await fixture.make()
            let repos = store.repos
            await seedOld(store)
            await repos.categories.create(title: "Defecto")
            await repos.library.add(new, chapters: newChapters, defaultCategory: "Defecto", adoptChapterFlags: nil)
            let options = MigrationOptions(categories: categories, keepOriginal: true)
            let outcome = try #require(await repos.library.migrate(request(options)))
            #expect(outcome.completions.map(\.chapter) == [chapter(newId, "n1")])
            // the original, as it was
            #expect(await repos.library.contains(oldId))
            #expect(await repos.chapters.chapters(of: oldId).map(\.key) == ["o3", "o2", "o1"])
            #expect(try #require(await repos.history.record(of: chapter(oldId, "o1"))).completed)
            #expect(try #require(await repos.history.record(of: chapter(oldId, "o2"))).progress == 4)
            #expect(await repos.categories.categories(of: oldId) == ["Antigua"])
            #expect(await repos.tracks.items(of: oldId).map(\.id) == ["t-1"])
            #expect(await store.seed.lastRead(of: oldId) == day(5))
            // the new one
            #expect(Set(await repos.categories.categories(of: newId)) == (categories ? ["Antigua", "Defecto"] : []))
            #expect(try #require(await repos.history.record(of: chapter(newId, "n1"))).completed)
            #expect(try #require(await repos.history.record(of: chapter(newId, "n2"))).progress == 4)
            #expect(await repos.tracks.items(of: newId).map(\.id) == ["t-1"])
            await store.tearDown()
        }
        // a new manga that was stored before keeps its own categories (the default one too)
        let store = try await fixture.make()
        let repos = store.repos
        await seedOld(store)
        await repos.categories.create(title: "Defecto")
        await repos.library.add(new, chapters: newChapters, defaultCategory: "Defecto", adoptChapterFlags: nil)
        #expect(await repos.library.migrate(request(MigrationOptions(categories: false, keepOriginal: true), newWasInLibrary: true)) != nil)
        #expect(await repos.categories.categories(of: newId) == ["Defecto"])
        await store.tearDown()
    }

    /// The unfinished chapter: its page goes to a new chapter whose history has no page yet, without a total when it
    /// had none (the stored total stays) and without touching the stored scroll position when it had none.
    @Test(arguments: repositoryFixtures)
    func anUnfinishedPageWithoutTotalKeepsTheStoredTotalAndPosition(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedOld(store)
        await store.seed.addHistory(HistorySeed(chapter: chapter(newId, "n2"), progress: 0, total: 15, dateRead: day(3), scrollPosition: 0.25))
        #expect(await repos.library.migrate(request(MigrationOptions())) != nil)
        let n2 = try #require(await repos.history.record(of: chapter(newId, "n2")))
        #expect(n2.progress == 4 && n2.total == 15 && n2.scrollPosition == 0.25 && n2.dateRead == day(2) && !n2.completed)
        await store.tearDown()
    }

    /// A tracker that cannot track the new manga: replacing deletes the track, keeping the original keeps it there
    /// and copies nothing.
    @Test(arguments: repositoryFixtures)
    func aTrackTheNewMangaCannotHave(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedOld(store)
        #expect(await repos.library.migrate(request(MigrationOptions(), canTrack: false)) != nil)
        #expect(await repos.tracks.items(of: newId).isEmpty)
        #expect(await repos.tracks.items(of: oldId).isEmpty)
        await store.tearDown()
        let copying = try await fixture.make()
        await seedOld(copying)
        await copying.repos.library.add(new, chapters: newChapters, defaultCategory: nil, adoptChapterFlags: nil)
        #expect(await copying.repos.library.migrate(request(MigrationOptions(keepOriginal: true), canTrack: false)) != nil)
        #expect(await copying.repos.tracks.items(of: newId).isEmpty)
        #expect(await copying.repos.tracks.items(of: oldId).map(\.id) == ["t-1"])
        await copying.tearDown()
    }

    /// A failed save: nil, and nothing half done (the old entry, its chapters, history, categories, track and date
    /// are as they were, and there is no new one).
    @Test(arguments: repositoryFixtures)
    func aFailedSaveLeavesTheStoreAsItWas(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let repos = store.repos
        await seedOld(store)
        #expect(await repos.manga.contains(oldId)) // the failing store sees the seed
        #expect(await store.failingRepos.library.migrate(request(MigrationOptions())) == nil)
        #expect(await repos.library.contains(oldId))
        #expect(await repos.manga.manga(oldId)?.title == "Viejo")
        #expect(await !repos.manga.contains(newId))
        #expect(await repos.chapters.chapters(of: oldId).map(\.key) == ["o3", "o2", "o1"])
        #expect(await repos.chapters.chapters(of: newId).isEmpty)
        #expect(try #require(await repos.history.record(of: chapter(oldId, "o1"))).completed)
        #expect(try #require(await repos.history.record(of: chapter(oldId, "o2"))).progress == 4)
        #expect(await repos.history.readingHistory(of: newId).isEmpty)
        #expect(await repos.categories.categories(of: oldId) == ["Antigua"])
        #expect(await repos.tracks.items(of: oldId).map(\.id) == ["t-1"])
        #expect(await store.seed.lastRead(of: oldId) == day(5))
        await store.tearDown()
    }

    /// The repository posts nothing about what it migrates (D6): the notifications stay with MangaManager.
    @Test(arguments: repositoryFixtures)
    func theRepositoryPostsNoNotifications(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await seedOld(store)
        let spy = NotificationSpy(key: key)
        let outcome = await store.repos.library.migrate(request(MigrationOptions()))
        spy.stop()
        #expect(outcome != nil)
        #expect(spy.names == [])
        await store.tearDown()
    }
}
