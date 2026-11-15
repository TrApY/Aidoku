//
//  MarkPreviousTests.swift
//  AidokuTests
//
//  SUWA-12 G1: «Marcar anteriores» marks the chapters before this one in the source's order, whatever
//  the order and the filters on screen.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@MainActor
@Suite(.serialized) struct MarkPreviousTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Source order: newest first, chapters 50…1, odd ones in Spanish, even ones in English.
    private func model(_ chapters: [AidokuRunner.Chapter]? = nil) -> MangaView.ViewModel {
        let list: [AidokuRunner.Chapter] = chapters ?? Self.fifty(base: base)
        var manga = AidokuRunner.Manga(sourceKey: "marcaranteriores", key: "m1", title: "Anteriores")
        manga.chapters = list
        let model = MangaView.ViewModel(source: nil, manga: manga)
        model.applyingStoredSort = true // these tests don't choose an order
        model.chapterSortAscending = false // shows the chapters
        return model
    }

    private static func fifty(base: Date) -> [AidokuRunner.Chapter] {
        var list: [AidokuRunner.Chapter] = []
        for number in (1...50).reversed() {
            let language: String = number % 2 == 1 ? "es" : "en"
            let date: Date = base.addingTimeInterval(Double(number) * 86_400)
            list.append(AidokuRunner.Chapter(key: "c\(number)", chapterNumber: Float(number), dateUploaded: date, language: language))
        }
        return list
    }

    private func previous(_ model: MangaView.ViewModel, _ key: String) throws -> [String] {
        let chapter = try #require(model.manga.chapters?.first { $0.key == key })
        return model.previousChapters(before: chapter).map(\.key)
    }

    private var oneToNineteen: Set<String> { Set((1...19).map { "c\($0)" }) }

    @Test func descending() throws {
        let model = model()
        #expect(Set(try previous(model, "c20")) == oneToNineteen)
    }

    @Test func ascending() throws {
        let model = model()
        model.chapterSortAscending = true
        #expect(model.chapters.first?.key == "c1")
        #expect(Set(try previous(model, "c20")) == oneToNineteen)
        #expect(try previous(model, "c1").isEmpty) // the first one has none
    }

    @Test func byUploadDate() throws {
        let model = model()
        model.chapterSortOption = .uploadDate
        model.chapterSortAscending = true
        #expect(Set(try previous(model, "c20")) == oneToNineteen)
    }

    @Test func withAFilterTheHiddenOnesCountToo() throws {
        let model = model()
        model.chapterLangFilter = "es"
        model.chapterSortAscending = true
        #expect(model.chapters.allSatisfy { $0.language == "es" })
        #expect(Set(try previous(model, "c21")) == Set((1...20).map { "c\($0)" }))
    }

    @Test func decimalsAndChaptersWithoutNumber() throws {
        // source order: 21, 20.5, extra (no number), 20, 19
        let model = model([
            .init(key: "c21", chapterNumber: 21),
            .init(key: "c20.5", chapterNumber: 20.5),
            .init(key: "extra", title: "Especial"),
            .init(key: "c20", chapterNumber: 20),
            .init(key: "c19", chapterNumber: 19)
        ])
        model.chapterSortAscending = true
        #expect(Set(try previous(model, "c21")) == ["c20.5", "extra", "c20", "c19"])
        #expect(Set(try previous(model, "c20.5")) == ["extra", "c20", "c19"])
        #expect(Set(try previous(model, "extra")) == ["c20", "c19"])
        #expect(try previous(model, "c20") == ["c19"])
    }
}
