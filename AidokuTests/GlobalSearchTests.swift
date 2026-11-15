//
//  GlobalSearchTests.swift
//  AidokuTests
//
//  Rows of the global and migration search, and the bulk migration pick.
//

import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct GlobalSearchTests {
    private let suwayomi = AidokuRunner.Source(key: "suwayomi-gs", name: "Suwayomi", version: 1, contentRating: .safe, runner: NoRunner())
    private let plain = AidokuRunner.Source(key: "plain-gs", name: "Otra", version: 1, contentRating: .safe, runner: NoRunner())
    private let olympus = "1596411039134168890"
    private let emperor = "4562754350961964148"

    private func manga(_ key: String, _ title: String, source: String = "suwayomi-gs") -> AidokuRunner.Manga {
        .init(sourceKey: source, key: key, title: title)
    }

    private func section(_ id: String, _ entries: [AidokuRunner.Manga]) -> GroupedSearchSection {
        .init(id: id, title: id == "library" ? "Biblioteca (Suwayomi)" : "Fuente \(id)", iconUrl: URL(string: "https://s.example/\(id)"), entries: entries)
    }

    @Test func oneRowPerServerSourceWithUniqueIds() throws {
        let rows = GlobalSearch.rows(source: suwayomi, sections: [
            section("library", [manga("1", "A")]),
            section(olympus, [manga("2", "B"), manga("3", "C")]),
            section(emperor, [])
        ])
        try #require(rows.count == 3)
        #expect(rows.map(\.id) == ["suwayomi-gs#library", "suwayomi-gs#\(olympus)", "suwayomi-gs#\(emperor)"])
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(rows.map(\.title) == ["Biblioteca (Suwayomi)", "Fuente \(olympus)", "Fuente \(emperor)"])
        #expect(rows[1].result.entries.map(\.key) == ["2", "3"])
        #expect(rows[1].imageUrl == URL(string: "https://s.example/\(olympus)"))
        #expect(rows[0].serverSourceId == nil)
        #expect(rows[1].serverSourceId == olympus)
        #expect(rows.allSatisfy { $0.source.key == "suwayomi-gs" && !$0.result.hasNextPage })
        // a source of its own keeps one row, with its own id and name
        let single = GlobalSearchRow(source: plain, result: .init(entries: [], hasNextPage: false))
        #expect(single.id == plain.id)
        #expect(single.title == "Otra")
    }

    @Test func theMigratedMangaIsNotAResult() {
        let old = manga("753", "Crónicas")
        let rows = GlobalSearch.excluding(old.identifier, from: GlobalSearch.rows(source: suwayomi, sections: [
            section("library", [old, manga("1", "A")]),
            section(olympus, [old, manga("2", "B")])
        ]))
        #expect(rows.map { $0.result.entries.map(\.key) } == [["1"], ["2"]])
        // same key in another source is another manga
        let other = GlobalSearch.excluding(old.identifier, from: [
            .init(source: plain, result: .init(entries: [manga("753", "Crónicas", source: "plain-gs")], hasNextPage: false))
        ])
        #expect(other.first?.result.entries.count == 1)
    }

    @Test func titlesAreComparedWithoutCaseAccentsOrSigns() {
        #expect(GlobalSearch.normalizedTitle("Crónicas de la facción: ¡Demoníaca! (Chun Hajin)")
            == GlobalSearch.normalizedTitle("cronicas de la faccion demoniaca chun hajin"))
        #expect(GlobalSearch.normalizedTitle("¡Ñandú, el 2!") == GlobalSearch.normalizedTitle("nandu el 2"))
        #expect(GlobalSearch.normalizedTitle("A") != GlobalSearch.normalizedTitle("B"))
    }

    @Test func bulkMigrationPrefersAnotherServerSourceAndTheSameTitle() {
        let title = "Cronicas de la faccion demoniaca (Chun hajin, el asesino mas fuerte)"
        let old = manga("753", title)
        let rows = GlobalSearch.rows(source: suwayomi, sections: [
            section("library", [old, manga("156", "Guía")]),
            section(olympus, [old, manga("754", title)]), // the old manga's own server source
            section(emperor, [manga("898", "El asesino de muñecas"), manga("897", "Crónicas de la facción demoníaca (Chun Hajin, el asesino más fuerte)")])
        ])
        // another source first, and in it the same title before the first result
        #expect(GlobalSearch.bestMatch(for: old, oldServerSourceId: olympus, rows: rows)?.key == "897")
        // without the same title there: the first result of another source
        let noTitle = GlobalSearch.rows(source: suwayomi, sections: [
            section(olympus, [old, manga("754", title)]),
            section(emperor, [manga("898", "El asesino de muñecas")])
        ])
        #expect(GlobalSearch.bestMatch(for: old, oldServerSourceId: olympus, rows: noTitle)?.key == "898")
        // its source unknown: only itself is left out (the same title first)
        #expect(GlobalSearch.bestMatch(for: old, oldServerSourceId: nil, rows: rows)?.key == "754")
        // only another source with nothing: what is left, never itself
        let onlyItself = GlobalSearch.rows(source: suwayomi, sections: [section("library", [old]), section(olympus, [old])])
        #expect(GlobalSearch.bestMatch(for: old, oldServerSourceId: olympus, rows: onlyItself) == nil)
    }

    @Test func otherSourcesKeepTheFirstResultButNeverItself() {
        let old = manga("1", "Uno", source: "plain-gs")
        let rows = [GlobalSearchRow(source: plain, result: .init(entries: [old, manga("2", "Dos", source: "plain-gs")], hasNextPage: false))]
        #expect(GlobalSearch.bestMatch(for: old, oldServerSourceId: nil, rows: rows)?.key == "2")
        let otherSource = manga("9", "Nueve")
        let first = [GlobalSearchRow(source: plain, result: .init(entries: [manga("3", "Tres", source: "plain-gs")], hasNextPage: false))]
        #expect(GlobalSearch.bestMatch(for: otherSource, oldServerSourceId: nil, rows: first)?.key == "3")
    }
}

/// A source that is never asked anything in these tests.
private final class NoRunner: AidokuRunner.Runner, @unchecked Sendable {
    let features = AidokuRunner.SourceFeatures()

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }
}
