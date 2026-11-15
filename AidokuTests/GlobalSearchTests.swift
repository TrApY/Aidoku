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
    // two sources of one Suwayomi server (each one a source of its own) and another source
    private let olympus = AidokuRunner.Source(key: "suwayomi.gs.1596411039134168890", name: "Olympus Scanlation", version: 1, contentRating: .safe, runner: NoRunner())
    private let emperor = AidokuRunner.Source(key: "suwayomi.gs.4562754350961964148", name: "Emperor Scan", version: 1, contentRating: .safe, runner: NoRunner())
    private let plain = AidokuRunner.Source(key: "plain-gs", name: "Otra", version: 1, contentRating: .safe, runner: NoRunner())

    private func manga(_ key: String, _ title: String, source: String = "suwayomi.gs.1596411039134168890") -> AidokuRunner.Manga {
        .init(sourceKey: source, key: key, title: title)
    }

    private func row(_ source: AidokuRunner.Source, _ entries: [AidokuRunner.Manga], failed: Bool = false) -> GlobalSearchRow {
        .init(source: source, result: .init(entries: entries, hasNextPage: false), failed: failed)
    }

    @Test func oneRowPerSourceNamedAfterIt() async {
        let rows = await GlobalSearch.rows(for: olympus, query: "x")
        #expect(rows.map(\.id) == [olympus.key])
        #expect(rows.map(\.title) == ["Olympus Scanlation"])
        #expect(rows.map(\.status) == [.noResults])
    }

    @Test func theMigratedMangaIsNotAResult() {
        let rows = [
            row(olympus, [manga("1", "A"), manga("2", "B")]),
            row(emperor, [manga("1", "A", source: emperor.key)]) // same server id, another source: a different manga
        ]
        let left = GlobalSearch.excluding(manga("1", "A").identifier, from: rows)
        #expect(left.map { $0.result.entries.map(\.key) } == [["2"], ["1"]])
        // a row left empty says «Sin resultados»
        let only = GlobalSearch.excluding(manga("1", "A").identifier, from: [row(olympus, [manga("1", "A")])])
        #expect(only.map(\.status) == [.noResults])
    }

    @Test func titlesAreComparedWithoutCaseAccentsOrSigns() {
        #expect(GlobalSearch.normalizedTitle("Crónicas: ¡Demoníaca!") == "cronicasdemoniaca")
        #expect(GlobalSearch.normalizedTitle("¡Ñandú, el 2!") == GlobalSearch.normalizedTitle("nandu el 2"))
        #expect(GlobalSearch.normalizedTitle("Solo Leveling") != GlobalSearch.normalizedTitle("Solo Leveling 2"))
    }

    @Test func bulkMigrationPrefersAnotherSourceAndTheSameTitle() {
        let old = manga("1", "Crónicas de la facción demoníaca")
        let rows = [
            row(olympus, [manga("5", "Crónicas de la facción demoníaca"), old]), // its own source
            row(emperor, [manga("8", "Otra cosa", source: emperor.key), manga("9", "Cronicas de la faccion demoniaca", source: emperor.key)])
        ]
        // another source first, and in it the same title before the first result
        #expect(GlobalSearch.bestMatch(for: old, rows: rows)?.identifier == manga("9", "", source: emperor.key).identifier)
        // only its own source: something else of it, never itself
        #expect(GlobalSearch.bestMatch(for: old, rows: [rows[0]])?.key == "5")
        #expect(GlobalSearch.bestMatch(for: old, rows: [row(olympus, [old])]) == nil)
        // other sources: the first result, as before
        #expect(GlobalSearch.bestMatch(for: old, rows: [row(plain, [manga("3", "Tres", source: "plain-gs")])])?.key == "3")
    }

    @Test func bulkMigrationTriesTheMangasOwnSourceLast() {
        let old = manga("1", "A")
        let order = GlobalSearch.targetOrder([olympus, plain, emperor], for: old).map(\.key)
        #expect(order == [plain.key, emperor.key, olympus.key])
        #expect(GlobalSearch.targetOrder([plain], for: old).map(\.key) == [plain.key])
    }

    @Test func emptyAndFailedSourcesKeepTheirRow() async {
        let failing = AidokuRunner.Source(key: "failing-gs", name: "Rota", version: 1, contentRating: .safe, runner: FailingRunner())
        #expect(await GlobalSearch.rows(for: failing, query: "x").map(\.status) == [.failed])
        #expect(await GlobalSearch.rows(for: plain, query: "x").map(\.status) == [.noResults])
        #expect(row(olympus, [manga("2", "B")]).status == .results)
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

/// A source that never answers.
private final class FailingRunner: AidokuRunner.Runner, @unchecked Sendable {
    let features = AidokuRunner.SourceFeatures()

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        throw URLError(.timedOut)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        throw URLError(.timedOut)
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }
}
