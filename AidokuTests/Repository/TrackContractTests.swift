//
//  TrackContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L1: the contract of TrackRepository, against every fixture (each test on a store of its own).
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct TrackContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    private let other = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m2")
    /// the same manga key under another source is another manga
    private let sameKeyOtherSource = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")

    private func item(_ id: String, _ tracker: String, _ manga: MangaIdentifier, title: String? = nil, offset: Int = 0) -> TrackItem {
        TrackItem(id: id, trackerId: tracker, mangaId: manga, title: title, chapterOffset: offset)
    }

    /// Items as comparable text (they come in no particular order).
    private func keys(_ items: [TrackItem]) -> [String] {
        items.map { "\($0.trackerId)|\($0.id)|\($0.mangaId.sourceKey)|\($0.mangaId.mangaKey)|\($0.title ?? "∅")|\($0.chapterOffset)" }.sorted()
    }

    @Test(arguments: repositoryFixtures)
    func anEmptyStoreHasNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        #expect(await tracks.items(of: manga).isEmpty)
        #expect(await tracks.items(trackerId: "anilist").isEmpty)
        #expect(await !tracks.contains(manga: manga))
        #expect(await !tracks.contains(trackerId: "anilist", manga: manga))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func addedItemsAreReadBackByMangaAndByTracker(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        #expect(await tracks.add(item("a1", "anilist", manga, title: "ñ漢字🙂", offset: 3)))
        #expect(await tracks.add(item("k1", "komga", manga, title: "")))
        #expect(await tracks.add(item("a2", "anilist", other)))
        #expect(await tracks.add(item("a3", "anilist", sameKeyOtherSource, offset: Int(Int16.max))))

        #expect(keys(await tracks.items(of: manga)) == ["anilist|a1|contract.source|m1|ñ漢字🙂|3", "komga|k1|contract.source|m1||0"])
        #expect(keys(await tracks.items(of: sameKeyOtherSource)) == ["anilist|a3|contract.other|m1|∅|32767"])
        #expect(keys(await tracks.items(trackerId: "anilist")).count == 3)
        #expect(keys(await tracks.items(trackerId: "komga")) == ["komga|k1|contract.source|m1||0"])
        #expect(await tracks.contains(manga: manga))
        #expect(await tracks.contains(trackerId: "komga", manga: manga))
        #expect(await !tracks.contains(trackerId: "komga", manga: other))
        #expect(await !tracks.contains(manga: MangaIdentifier(sourceKey: "contract.source", mangaKey: "nadie")))
        await store.tearDown()
    }

    /// `add` does not deduplicate (documented): callers ask `contains(trackerId:manga:)` first.
    @Test(arguments: repositoryFixtures)
    func addingTwiceGivesTwoItems(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        #expect(await tracks.add(item("a1", "anilist", manga)))
        #expect(await tracks.add(item("a1", "anilist", manga)))
        #expect(await tracks.items(of: manga).count == 2)
        // removing that tracker's item for the manga takes one of them
        #expect(await tracks.remove(trackerId: "anilist", manga: manga))
        #expect(await tracks.items(of: manga).count == 1)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func theChapterOffsetChangesOnlyThatItem(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        await tracks.add(item("a1", "anilist", manga))
        await tracks.add(item("k1", "komga", manga))
        await tracks.add(item("a2", "anilist", other))
        #expect(await tracks.setChapterOffset(trackerId: "anilist", manga: manga, offset: -2))
        #expect(await tracks.setChapterOffset(trackerId: "anilist", manga: manga, offset: -2)) // idempotent
        #expect(keys(await tracks.items(of: manga)) == ["anilist|a1|contract.source|m1|∅|-2", "komga|k1|contract.source|m1|∅|0"])
        #expect(keys(await tracks.items(of: other)) == ["anilist|a2|contract.source|m2|∅|0"])
        // no such item: nothing changes and the save goes well
        #expect(await tracks.setChapterOffset(trackerId: "mal", manga: manga, offset: 5))
        #expect(await tracks.items(trackerId: "mal").isEmpty)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func removingTouchesNeitherOtherTrackersNorOtherManga(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        await tracks.add(item("a1", "anilist", manga))
        await tracks.add(item("k1", "komga", manga))
        await tracks.add(item("a2", "anilist", other))
        await tracks.add(item("a3", "anilist", sameKeyOtherSource))
        #expect(await tracks.remove(trackerId: "anilist", manga: manga))
        #expect(await tracks.remove(trackerId: "anilist", manga: manga)) // again: nothing to remove, saves well
        #expect(keys(await tracks.items(of: manga)) == ["komga|k1|contract.source|m1|∅|0"])
        #expect(await tracks.items(of: other).count == 1)
        #expect(await tracks.items(of: sameKeyOtherSource).count == 1)
        #expect(await tracks.contains(manga: manga))
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func removeAllOfATrackerKeepsTheOthers(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        await tracks.add(item("a1", "anilist", manga))
        await tracks.add(item("a2", "anilist", other))
        await tracks.add(item("k1", "komga", manga))
        #expect(await tracks.removeAll(trackerId: "anilist"))
        #expect(await tracks.items(trackerId: "anilist").isEmpty)
        #expect(keys(await tracks.items(trackerId: "komga")) == ["komga|k1|contract.source|m1|∅|0"])
        #expect(await tracks.removeAll(trackerId: "anilist")) // nothing left: saves well
        await store.tearDown()
    }

    /// Komga/Kavita/Suwayomi forget the items of one server source: only their tracker, only matching ids.
    @Test(arguments: repositoryFixtures)
    func removeAllWhereRemovesOnlyMatchingIdsOfThatTracker(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        await tracks.add(item("server.a|1", "komga", manga))
        await tracks.add(item("server.a|2", "komga", other))
        await tracks.add(item("server.b|3", "komga", sameKeyOtherSource))
        await tracks.add(item("server.a|1", "kavita", manga)) // same id, another tracker
        #expect(await tracks.removeAll(trackerId: "komga", where: { $0.hasPrefix("server.a|") }))
        #expect(keys(await tracks.items(trackerId: "komga")) == ["komga|server.b|3|contract.other|m1|∅|0"])
        #expect(await tracks.items(trackerId: "kavita").count == 1)
        await store.tearDown()
    }

    /// A predicate that throws (an id it cannot read) removes nothing, as before, whichever item it throws on: it
    /// takes the first id it is given and throws on the next one, so the order of the fetch does not matter (bajo nº 2).
    @Test(arguments: repositoryFixtures)
    func aThrowingPredicateRemovesNothing(fixture: any RepositoryFixture) async throws {
        struct Unreadable: Error {}
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        await tracks.add(item("server.a|1", "komga", manga))
        await tracks.add(item("server.a|2", "komga", other))
        let calls = PredicateCalls()
        let removed = await tracks.removeAll(trackerId: "komga", where: { _ in
            guard calls.next() == 1 else { throw Unreadable() }
            return true
        })
        #expect(!removed)
        #expect(await tracks.items(trackerId: "komga").count == 2)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func clearAllRemovesEveryTracker(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let tracks = store.repos.tracks
        await tracks.add(item("a1", "anilist", manga))
        await tracks.add(item("k1", "komga", other))
        #expect(await tracks.clearAll())
        #expect(await !tracks.contains(manga: manga))
        #expect(await !tracks.contains(manga: other))
        #expect(await tracks.clearAll())
        await store.tearDown()
    }

    /// The tracking badge reads synchronously on the main thread the same thing as `contains(manga:)`.
    @Test(arguments: repositoryFixtures)
    func theMainThreadReadSeesTheSame(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let manga = self.manga
        let other = self.other
        await store.repos.tracks.add(item("a1", "anilist", manga))
        let reads = store.repos.mainActorReads
        let (tracked, untracked) = await MainActor.run { (reads.isTracking(manga), reads.isTracking(other)) }
        #expect(tracked)
        #expect(!untracked)
        await store.tearDown()
    }
}

/// How many times a predicate was called.
final class PredicateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// 1 the first time, 2 the second…
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
