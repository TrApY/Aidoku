//
//  HistoryReadStateContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-4): registering a tracker reads the highest number read and the earliest read date of a
//  manga together, from one context, as it did before.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct HistoryReadStateContractTests {
    private let manga = MangaIdentifier(sourceKey: "contract.source", mangaKey: "m1")
    /// the same key in another source
    private let other = MangaIdentifier(sourceKey: "contract.other", mangaKey: "m1")

    private func day(_ n: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + n * 86_400) }

    private func id(_ key: String, _ manga: MangaIdentifier) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    @Test(arguments: repositoryFixtures)
    func bothNumbersComeFromTheCompletedChapters(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let history = store.repos.history
        await store.seed.addChapters([
            AidokuRunner.Chapter(key: "c1", chapterNumber: 1, volumeNumber: 1),
            AidokuRunner.Chapter(key: "c2", chapterNumber: 3, volumeNumber: 2),
            AidokuRunner.Chapter(key: "c3", chapterNumber: 5, volumeNumber: 3)
        ], to: manga)
        await store.seed.addChapters([AidokuRunner.Chapter(key: "c9", chapterNumber: 9, volumeNumber: 9)], to: other)
        await store.seed.addHistory(HistorySeed(chapter: id("c1", manga), progress: 4, total: 4, completed: true, dateRead: day(2)))
        await store.seed.addHistory(HistorySeed(chapter: id("c2", manga), progress: 4, total: 4, completed: true, dateRead: day(1)))
        // read but not completed: neither the number nor the date
        await store.seed.addHistory(HistorySeed(chapter: id("c3", manga), progress: 2, total: 4, dateRead: day(0)))
        await store.seed.addHistory(HistorySeed(chapter: id("c9", other), progress: 4, total: 4, completed: true, dateRead: day(-5)))

        #expect(await history.readState(of: manga, mode: .default) == HistoryReadState(highestReadNumber: 3, earliestReadDate: day(1)))
        #expect(await history.readState(of: manga, mode: .volume) == HistoryReadState(highestReadNumber: 2, earliestReadDate: day(1)))
        #expect(await history.readState(of: other, mode: .default) == HistoryReadState(highestReadNumber: 9, earliestReadDate: day(-5)))
        // the same as the two reads apart
        for mode in ChapterTitleDisplayMode.allCases {
            let apart = HistoryReadState(
                highestReadNumber: await history.highestReadNumber(of: manga, mode: mode),
                earliestReadDate: await history.earliestReadDate(of: manga)
            )
            #expect(await history.readState(of: manga, mode: mode) == apart, "\(mode)")
        }
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func noHistoryIsNothing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        await store.seed.addChapters([AidokuRunner.Chapter(key: "c1", chapterNumber: 1)], to: manga)
        #expect(await store.repos.history.readState(of: manga, mode: .default) == HistoryReadState(highestReadNumber: nil, earliestReadDate: nil))
        await store.tearDown()
    }
}
