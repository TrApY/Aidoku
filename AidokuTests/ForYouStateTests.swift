//
//  ForYouStateTests.swift
//  AidokuTests
//
//  SUWA-18 A3: Explorar › «Para ti»: the fourth tab, its states and texts, «Actualizado: <at>» and the
//  reads (once per session, again on pull to refresh) against a fake GraphQL transport.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

/// A text of the app in Spanish (the contract's texts are Spanish).
private func spanish(_ key: String) -> String? {
    guard let path = Bundle.main.path(forResource: "es", ofType: "lproj"), let bundle = Bundle(path: path) else {
        return nil
    }
    let text = bundle.localizedString(forKey: key, value: "·sin traducir·", table: nil)
    return text == "·sin traducir·" ? nil : text
}

@MainActor
@Suite(.serialized) struct ForYouStateTests {
    let key = "suwayomi.recs-a3"
    let server = SuwayomiFakeServer()

    private func result(entries: [Int], at: String? = "2026-11-18T01:11:32+01:00", ok: Bool? = true) -> SuwayomiRecs.ForYouResult {
        .init(
            at: at,
            entries: entries.map {
                .init(mangaId: $0, sourceKey: "\(key).\(RecsFixture.crab)", title: "Manga \($0)", cover: nil, reason: "r", sourceName: "Manga Crab")
            },
            status: ok.map { .init(at: "2026-11-19T04:31:00+01:00", ok: $0, message: nil) }
        )
    }

    private func spanishDate(_ at: String?) -> String? {
        SuwayomiRecs.updatedText(
            at: at,
            format: spanish("FOR_YOU_UPDATED") ?? "",
            locale: Locale(identifier: "es_ES"),
            timeZone: TimeZone(identifier: "Europe/Madrid") ?? .current
        )
    }

    @Test func forYouIsTheFourthTabOfExplorar() {
        #expect(BrowseTab.shown.map(\.titleKey) == ["EXPLORE_SOURCES", "EXPLORE_EXTENSIONS", "EXPLORE_MIGRATE", "EXPLORE_FOR_YOU"])
        #expect(BrowseTab.shown.firstIndex(of: .forYou) == 3)
        #expect(BrowseTab.shown.map(\.rawValue) == Array(0..<BrowseTab.shown.count))
        #expect(spanish("EXPLORE_FOR_YOU") == "Para ti")
    }

    @Test func withoutAConnectionItAsksToConnectTheServer() {
        let state = ForYouState.make(hasConnection: false, result: nil, failed: false, shown: nil)
        #expect(state == .noServer)
        #expect(state.messageKey.flatMap(spanish) == "Conecta el servidor Suwayomi en Ajustes")
    }

    @Test func withoutRecommendationsItSaysTheyAreComputedEveryNight() {
        let state = ForYouState.make(hasConnection: true, result: result(entries: []), failed: false, shown: nil)
        #expect(state == .empty)
        #expect(state.messageKey.flatMap(spanish) == "Aún no hay recomendaciones: se calculan cada noche")
    }

    @Test func aFailedReadWithNothingShownOffersARetry() {
        let state = ForYouState.make(hasConnection: true, result: nil, failed: true, shown: nil)
        #expect(state == .error)
        #expect(state.messageKey.flatMap(spanish) != nil)
        #expect(spanish("RETRY") == "Reintentar")
    }

    @Test func aFailedReadKeepsWhatWasShown() {
        let shown = result(entries: [1645, 291])
        let state = ForYouState.make(hasConnection: true, result: nil, failed: true, shown: shown, updatedText: { $0 })
        #expect(state == .loaded(updated: shown.at, entries: shown.entries))
    }

    @Test func theListShowsUpdatedWithTheDateOfTheRecommendations() throws {
        let state = ForYouState.make(hasConnection: true, result: result(entries: [1645]), failed: false, shown: nil, updatedText: spanishDate)
        guard case let .loaded(updated, entries) = state else {
            Issue.record("estado \(state)")
            return
        }
        #expect(entries.map(\.mangaId) == [1645])
        let text = try #require(updated)
        #expect(text.hasPrefix("Actualizado: "))
        #expect(text.contains("18"))
        #expect(text.contains("1:11"))
    }

    @Test func aFailedLastRunKeepsTheListAndTheDateOfTheRecommendations() {
        // estado.at is the 19th: «Actualizado» stays the date of suwa.recs.v1 (the 18th)
        let state = ForYouState.make(hasConnection: true, result: result(entries: [1645], ok: false), failed: false, shown: nil, updatedText: spanishDate)
        guard case let .loaded(updated, entries) = state else {
            Issue.record("estado \(state)")
            return
        }
        #expect(entries.map(\.mangaId) == [1645])
        #expect(updated?.contains("18") == true)
        #expect(updated?.contains("19") == false)
    }

    @Test func anUnreadableDateShowsNoLine() {
        #expect(spanishDate(nil) == nil)
        #expect(spanishDate("ayer") == nil)
    }

    // MARK: Reads

    private func model(connection: String? = "suwayomi.recs-a3", cache: SuwayomiRecsCache) -> ForYouViewModel {
        RecsFixture.setServer(key)
        return ForYouViewModel(connection: { connection }, cache: cache, transport: server.transport)
    }

    private func respond() {
        server.respond("SuwaRecsForYou", .success(RecsFixture.forYouAnswer(
            recs: RecsFixture.list([(1645, RecsFixture.crab, "uno"), (291, RecsFixture.insanos, "dos")]),
            estado: RecsFixture.status(ok: true)
        )))
        server.respond("SuwaRecsMangas", .success(RecsFixture.mangasAnswer([
            (1645, "Paladín", RecsFixture.crab, false), (291, "Extiendo", RecsFixture.insanos, false)
        ])))
    }

    private func shownIds(_ state: ForYouState) -> [Int] {
        if case let .loaded(_, entries) = state { return entries.map(\.mangaId) }
        return []
    }

    @Test func theTabReadsOncePerSessionAndAgainOnPullToRefresh() async {
        defer { RecsFixture.clearServer(key) }
        respond()
        let cache = SuwayomiRecsCache(directory: nil)
        let viewModel = model(cache: cache)
        await viewModel.loadIfNeeded()
        #expect(shownIds(viewModel.state) == [1645, 291])
        await viewModel.loadIfNeeded()
        // another visit in the same session (a new view): the memory copy, no read
        let again = model(cache: cache)
        await again.loadIfNeeded()
        #expect(shownIds(again.state) == [1645, 291])
        #expect(server.count("SuwaRecsForYou") == 1)
        await viewModel.load(force: true)
        #expect(server.count("SuwaRecsForYou") == 2)
    }

    @Test func aFailedRefreshKeepsTheList() async {
        defer { RecsFixture.clearServer(key) }
        respond()
        let viewModel = model(cache: SuwayomiRecsCache(directory: nil))
        await viewModel.loadIfNeeded()
        server.respond("SuwaRecsForYou", .failure(URLError(.timedOut)))
        await viewModel.load(force: true)
        #expect(shownIds(viewModel.state) == [1645, 291])
    }

    @Test func withoutAConnectionNothingIsAsked() async {
        respond()
        let viewModel = model(connection: nil, cache: SuwayomiRecsCache(directory: nil))
        await viewModel.loadIfNeeded()
        #expect(viewModel.state == .noServer)
        #expect(server.count("SuwaRecsForYou") == 0)
        RecsFixture.clearServer(key)
    }
}
