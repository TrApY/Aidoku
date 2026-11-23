//
//  LibraryRefreshOriginTests.swift
//  AidokuTests
//
//  SUWA-34 P3: the user's pull to refresh (library and manga page) makes the Suwayomi runner search the
//  scan's website (`SuwayomiServerSources.forceOriginFetch`); scheduled refreshes never do.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

/// What each library refresh body run saw as `forceOrigin`.
private actor BodyLog {
    private(set) var values: [Bool] = []

    func add(_ value: Bool) { values.append(value) }

    func wait(count: Int, seconds: TimeInterval = 5) async -> [Bool] {
        let deadline = Date().addingTimeInterval(seconds)
        while values.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return values
    }
}

/// The manga page's source: records `forceOriginFetch` as seen inside `getMangaUpdate`.
private final class OriginProbeRunner: AidokuRunner.Runner, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    let features = AidokuRunner.SourceFeatures()

    var seen: [Bool] { lock.withLock { values } }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        lock.withLock { values.append(SuwayomiServerSources.forceOriginFetch) }
        var manga = manga
        if needsChapters {
            manga.chapters = []
        }
        return manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }
}

@Suite(.serialized) struct LibraryRefreshOriginTests {
    // MARK: The wrapper

    @Test func theWrapperSetsTheTaskLocalOnlyInside() async {
        #expect(SuwayomiServerSources.forceOriginFetch == false)
        let forced = await SuwayomiServerSources.withOriginFetch(forced: true) { SuwayomiServerSources.forceOriginFetch }
        #expect(forced == true)
        let notForced = await SuwayomiServerSources.withOriginFetch(forced: false) { SuwayomiServerSources.forceOriginFetch }
        #expect(notForced == false)
        #expect(SuwayomiServerSources.forceOriginFetch == false)
    }

    @Test func notForcedInsideForcedIsNotForced() async {
        let inner = await SuwayomiServerSources.withOriginFetch(forced: true) {
            await SuwayomiServerSources.withOriginFetch(forced: false) { SuwayomiServerSources.forceOriginFetch }
        }
        #expect(inner == false)
    }

    // MARK: The library refresh remembers who asked for it

    private func makeManager(_ log: BodyLog, stayWhile holdUserRefresh: Bool = false) -> MangaManager {
        MangaManager(
            libraryRefreshBody: { forceOrigin in
                await log.add(forceOrigin)
                // a refresh that goes on until it is cancelled
                while holdUserRefresh, forceOrigin, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            },
            reschedule: {}
        )
    }

    @Test func aRefreshAskedByTheUserForcesTheOrigin() async {
        let log = BodyLog()
        let manager = makeManager(log)
        await manager.backgroundRefreshLibrary(fromUser: true)
        #expect(await log.values == [true])
    }

    @Test func aRefreshNotAskedByTheUserDoesNot() async {
        let log = BodyLog()
        let manager = makeManager(log)
        await manager.backgroundRefreshLibrary()
        await manager.backgroundRefreshLibrary(fromUser: false)
        await manager.refreshLibrary() // scheduled, resumed at launch
        #expect(await log.values == [false, false, false])
    }

    @Test func theNextScheduledRefreshGoesBackToFalse() async {
        let log = BodyLog()
        let manager = makeManager(log)
        await manager.backgroundRefreshLibrary(category: "Lectura", fromUser: true)
        await manager.refreshLibrary()
        #expect(await log.values == [true, false])
    }

    @Test func theNextScheduledRefreshGoesBackToFalseAlsoAfterACancelledOne() async {
        let log = BodyLog()
        let manager = makeManager(log, stayWhile: true)
        let user = Task { await manager.backgroundRefreshLibrary(fromUser: true) }
        #expect(await log.wait(count: 1) == [true])
        await manager.libraryRefreshTask?.cancel() // what the background task's expiration does
        await user.value
        await manager.refreshLibrary()
        #expect(await log.values == [true, false])
    }

    // MARK: The manga page

    @Test func theMangaPageRefreshRunsForced() async throws {
        let runner = OriginProbeRunner()
        let manga = AidokuRunner.Manga(sourceKey: "suwa34.ficha", key: "1", title: "Ficha de prueba")
        let source = AidokuRunner.Source(key: manga.sourceKey, name: "Ficha", version: 1, contentRating: .safe, runner: runner)
        let viewModel = await MainActor.run { MangaView.ViewModel(source: source, manga: manga) }
        await viewModel.refresh()
        #expect(runner.seen == [true])
        #expect(SuwayomiServerSources.forceOriginFetch == false) // nothing leaks out of the refresh
    }
}
