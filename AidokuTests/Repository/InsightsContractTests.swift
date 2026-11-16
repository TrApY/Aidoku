//
//  InsightsContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L10: the reading statistics read together (§1.3 nº 25), against every fixture, as they are today.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct InsightsContractTests {
    private let a = MangaIdentifier(sourceKey: "contract.source", mangaKey: "a")
    private let b = MangaIdentifier(sourceKey: "contract.source", mangaKey: "b")

    private func chapter(_ manga: MangaIdentifier, _ key: String) -> ChapterIdentifier {
        ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.mangaKey, chapterKey: key)
    }

    @Test(arguments: repositoryFixtures)
    func withoutSessionsEverythingIsZero(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let insights = await store.repos.sessions.insights()
        #expect(insights.currentStreak == 0)
        #expect(insights.longestStreak == 0)
        #expect([insights.pagesTotal, insights.pagesMonth, insights.pagesYear, insights.seriesTotal, insights.seriesMonth,
                 insights.seriesYear, insights.hoursTotal, insights.hoursMonth, insights.hoursYear] == Array(repeating: 0, count: 9))
        #expect(insights.heatmap.values.allSatisfy { $0 == 0 })
        await store.tearDown()
    }

    /// Today, yesterday and 400 days ago: the streak is today and yesterday; the hours are whole hours of the sum.
    @Test(arguments: repositoryFixtures)
    func theFourStatistics(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sessions = store.repos.sessions
        let now = Date.now.addingTimeInterval(-60)
        let yesterday = now.addingTimeInterval(-86_400)
        let old = now.addingTimeInterval(-400 * 86_400)
        let seeded: [(ChapterIdentifier, Date, TimeInterval, Int)] = [
            (chapter(a, "1"), now, 2 * 3600, 10),
            (chapter(b, "1"), yesterday, 1.5 * 3600, 5),
            (chapter(a, "2"), old, 3600, 7)
        ]
        for (id, end, duration, pages) in seeded {
            #expect(await sessions.add(.init(startDate: end.addingTimeInterval(-duration), endDate: end, pagesRead: pages), chapter: id))
        }
        let insights = await sessions.insights()
        #expect(insights.currentStreak == 2)
        #expect(insights.longestStreak == 2)
        #expect(insights.pagesTotal == 22)
        #expect(insights.seriesTotal == 2)
        #expect(insights.hoursTotal == 4)
        let calendar = Calendar.current
        let thisYear = seeded.filter { calendar.component(.year, from: $0.1) == calendar.component(.year, from: .now) }
        let thisMonth = thisYear.filter { calendar.component(.month, from: $0.1) == calendar.component(.month, from: .now) }
        #expect(insights.pagesYear == thisYear.map(\.3).reduce(0, +))
        #expect(insights.pagesMonth == thisMonth.map(\.3).reduce(0, +))
        #expect(insights.seriesYear == Set(thisYear.map(\.0.mangaIdentifier)).count)
        #expect(insights.hoursYear == Int(thisYear.map(\.2).reduce(0, +) / 3600))
        #expect(insights.hoursMonth == Int(thisMonth.map(\.2).reduce(0, +) / 3600))
        // the chart is by year; the heatmap covers the last year
        #expect(Set(insights.chart.map(\.year)) == Set(seeded.map { calendar.component(.year, from: $0.1) }))
        let (days, start) = HeatmapData.getDaysAndStartDate()
        #expect(insights.heatmap.startDate == start)
        #expect(insights.heatmap.values.count == days)
        #expect(insights.heatmap.values.reduce(0, +) > 0)
        await store.tearDown()
    }
}
