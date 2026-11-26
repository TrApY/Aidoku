//
//  HistoryMigrationContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-6): the 0.6 migration of the history (at launch and from Settings › Advanced). It links
//  each history row without a chapter to its stored chapter, leaves the linked ones as they are, can run again and
//  tells its progress from 0.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

/// The progress values a migration told, in order.
final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []

    func add(_ value: Float) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite(.serialized) struct HistoryMigrationContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")

    private func id(_ key: String) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    @Test(arguments: repositoryFixtures)
    func theRowsWithoutAChapterAreLinked(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addChapters([.init(key: "c1"), .init(key: "c2")], to: manga)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 3, linked: false))
        await store.seed.addHistory(HistorySeed(chapter: id("c2"), progress: 5))
        // a row whose chapter is not stored stays without one
        await store.seed.addHistory(HistorySeed(chapter: id("c9"), progress: 1, linked: false))
        #expect(await !store.seed.isLinked(id("c1")))

        let progress = ProgressValues()
        #expect(await history.migrateChapterLinks { progress.add($0) })
        #expect(await store.seed.isLinked(id("c1")))
        #expect(await store.seed.isLinked(id("c2")))
        #expect(await !store.seed.isLinked(id("c9")))
        #expect(await store.seed.historyRows(of: id("c1")) == 1)
        #expect(await store.seed.historyRows(of: id("c2")) == 1)
        #expect(await history.progress(of: id("c1")) == ChapterProgress(completed: false, progress: 3))
        // one value per row, from 0, going up, below 1
        let told = progress.values
        #expect(told.count == 3)
        #expect(told.first == 0)
        #expect(told == told.sorted())
        #expect(told.allSatisfy { $0 >= 0 && $0 < 1 })

        // again: the same
        #expect(await history.migrateChapterLinks { _ in })
        #expect(await store.seed.isLinked(id("c1")))
        #expect(await store.seed.isLinked(id("c2")))
        #expect(await !store.seed.isLinked(id("c9")))
        #expect(await store.seed.historyRows(of: id("c1")) == 1)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func aFailedSaveLinksNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await store.seed.addChapters([.init(key: "c1")], to: manga)
        await store.seed.addHistory(HistorySeed(chapter: id("c1"), progress: 3, linked: false))
        #expect(await !store.failingRepos.history.migrateChapterLinks { _ in })
        #expect(await !store.seed.isLinked(id("c1")))
        await store.tearDown()
    }
}
