//
//  MarkPreviousMoreTests.swift
//  AidokuTests
//
//  SUWA-12 H7: the cases the review of G missed. Another scan of the same number isn't «previous»; volumes
//  without a chapter number go by the source's order; opening the manga page doesn't save an order.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@MainActor
@Suite(.serialized) struct MarkPreviousMoreTests {
    private func previous(_ key: String, in chapters: [AidokuRunner.Chapter]) throws -> Set<String> {
        let chapter = try #require(chapters.first { $0.key == key })
        return Set(ChapterOrder.previous(of: chapter, inSourceOrder: chapters).map(\.key))
    }

    @Test func anotherScanOfTheSameNumberIsNotPrevious() throws {
        let chapters: [AidokuRunner.Chapter] = [
            .init(key: "21a", chapterNumber: 21, scanlators: ["A"]),
            .init(key: "20a", chapterNumber: 20, scanlators: ["A"]),
            .init(key: "20b", chapterNumber: 20, scanlators: ["B"]),
            .init(key: "19a", chapterNumber: 19, scanlators: ["A"])
        ]
        #expect(try previous("20a", in: chapters) == ["19a"])
        #expect(try previous("20b", in: chapters) == ["19a"])
    }

    @Test func volumesWithoutAChapterNumberGoByTheSourceOrder() throws {
        let chapters: [AidokuRunner.Chapter] = [
            .init(key: "v3", title: "Tomo 3", volumeNumber: 3),
            .init(key: "v2", title: "Tomo 2", volumeNumber: 2),
            .init(key: "v1", title: "Tomo 1", volumeNumber: 1)
        ]
        #expect(try previous("v2", in: chapters) == ["v1"])
        #expect(try previous("v1", in: chapters).isEmpty)
    }

    @Test func openingTheMangaPageDoesNotSaveAnOrder() async throws {
        let manga = AidokuRunner.Manga(sourceKey: "ordenabrir", key: "abrir", title: "Abrir")
        defer { ChapterSortMemory.forgetLocal(manga.identifier) }
        let model = MangaView.ViewModel(source: nil, manga: manga)
        await model.fetchDetails()
        // its own order isn't saved (the default is shared with other suites running at the same time)
        #expect(ChapterSortMemory.local(for: manga.identifier) == nil)
    }
}
