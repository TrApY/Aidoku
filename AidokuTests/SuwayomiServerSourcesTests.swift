//
//  SuwayomiServerSourcesTests.swift
//  AidokuTests
//
//  Server sources for the built-in Suwayomi source: GraphQL request building and
//  decoding of real responses recorded from a Suwayomi-Server v2.4 (Fixtures/Suwayomi).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

private final class FixtureToken {}

private func fixture(_ name: String) throws -> Data {
    let fileName = "suwayomi-\(name)"
    if let url = Bundle(for: FixtureToken.self).url(forResource: fileName, withExtension: "json") {
        return try Data(contentsOf: url)
    }
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Suwayomi/\(fileName).json")
    return try Data(contentsOf: url)
}

private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let mangaDexEs = "6400665728063187402"
private let baseUrl = URL(string: "https://suwayomi.example:4567/")!

private func serverSources() throws -> [SuwayomiServerSource] {
    try JSONDecoder().decode(SuwayomiSourcesResponse.self, from: fixture("sources")).data.sources.nodes
}

private func source(id: String, name: String, supportsLatest: Bool, isNsfw: Bool = false) -> SuwayomiServerSource {
    .init(id: id, name: name, lang: "es", displayName: name, isNsfw: isNsfw, supportsLatest: supportsLatest, iconUrl: nil)
}

@Suite struct SuwayomiServerSourcesTests {
    // MARK: Sources setting

    @Test func decodesInstalledSources() throws {
        let sources = try serverSources()
        #expect(sources.count == 63)
        let es = try #require(sources.first { $0.id == mangaDexEs })
        #expect(es.displayName == "MangaDex (ES)")
        #expect(es.lang == "es")
        #expect(es.supportsLatest)
        #expect(es.isNsfw)
        #expect(sources.contains { $0.id == SuwayomiServerSources.localSourceId })
    }

    @Test func availableSourcesSkipLocalSourceAndRespectNsfw() throws {
        let sources = try serverSources()
        let all = SuwayomiServerSources.available(sources, allowNsfw: true)
        #expect(all.count == 62)
        #expect(!all.contains { $0.id == "0" })
        // every MangaDex language is flagged as NSFW by the extension
        #expect(SuwayomiServerSources.available(sources, allowNsfw: false).isEmpty)

        let mixed = [source(id: "1", name: "Safe", supportsLatest: true), source(id: "2", name: "Adult", supportsLatest: true, isNsfw: true)]
        #expect(SuwayomiServerSources.available(mixed, allowNsfw: false).map(\.id) == ["1"])
    }

    @Test func nsfwFollowsAppContentRatings() {
        #expect(SuwayomiServerSources.allowsNsfw(contentRatings: [.safe, .containsNsfw])) // app default
        #expect(SuwayomiServerSources.allowsNsfw(contentRatings: [.safe, .containsNsfw, .primarilyNsfw]))
        #expect(!SuwayomiServerSources.allowsNsfw(contentRatings: [.safe]))
        #expect(!SuwayomiServerSources.allowsNsfw(contentRatings: []))
    }

    @Test func settingOffersEverySourceAndRefreshesListingsAndFilters() throws {
        let available = SuwayomiServerSources.available(try serverSources(), allowNsfw: true)
        let setting = try #require(SuwayomiServerSources.setting(sources: available))
        guard case let .group(group) = setting.value else {
            Issue.record("expected a group")
            return
        }
        let item = try #require(group.items.first)
        #expect(item.key == "serverSources")
        #expect(item.refreshes.contains("listings"))
        #expect(item.refreshes.contains("filters"))
        guard case let .multiselect(multiselect) = item.value else {
            Issue.record("expected a multiselect")
            return
        }
        #expect(multiselect.values.count == 62)
        #expect(multiselect.values.contains(mangaDexEs))
        let index = try #require(multiselect.values.firstIndex(of: mangaDexEs))
        #expect(multiselect.titles?[index] == "MangaDex (ES)")
        #expect(SuwayomiServerSources.setting(sources: []) == nil)
        #expect(SuwayomiServerSources.defaultsKey(sourceKey: "suwayomi") == "suwayomi.serverSources")
    }

    // MARK: Listings

    @Test func listingsFollowTheSettingOrder() throws {
        let available = SuwayomiServerSources.available(try serverSources(), allowNsfw: true)
        let en = try #require(available.first { $0.displayName == "MangaDex (EN)" })
        let selected = SuwayomiServerSources.selected(ids: [mangaDexEs, en.id, "missing"], from: available)
        let expected = available.filter { $0.id == mangaDexEs || $0.id == en.id }.map(\.id)
        #expect(selected.map(\.id) == expected)

        let listings = SuwayomiServerSources.listings(for: selected)
        #expect(listings.count == 4)
        let es = listings.filter { $0.id.hasSuffix(mangaDexEs) }
        #expect(es.map(\.id) == ["popular-\(mangaDexEs)", "latest-\(mangaDexEs)"])
        #expect(es.allSatisfy { $0.name.contains("MangaDex (ES)") })
        try #require(es.count == 2)
        #expect(es[0].name == String(format: NSLocalizedString("SUWAYOMI_LISTING_POPULAR"), "MangaDex (ES)"))
        #expect(es[1].name == String(format: NSLocalizedString("SUWAYOMI_LISTING_LATEST"), "MangaDex (ES)"))
        #expect(!es[0].name.contains("SUWAYOMI_LISTING"))
    }

    @Test func noLatestListingWithoutLatestSupport() {
        let listings = SuwayomiServerSources.listings(for: [source(id: "7", name: "Solo populares", supportsLatest: false)])
        #expect(listings.map(\.id) == ["popular-7"])
        #expect(SuwayomiServerSources.listings(for: []).isEmpty)
        #expect(SuwayomiServerSources.selected(ids: [], from: [source(id: "7", name: "X", supportsLatest: true)]).isEmpty)
    }

    @Test func parsesListingIds() throws {
        let popular = try #require(SuwayomiServerSources.parseListingId("popular-\(mangaDexEs)"))
        #expect(popular.type == .popular)
        #expect(popular.sourceId == mangaDexEs)
        let latest = try #require(SuwayomiServerSources.parseListingId("latest-42"))
        #expect(latest.type == .latest)
        #expect(latest.sourceId == "42")
        #expect(SuwayomiServerSources.parseListingId("library-1") == nil)
        #expect(SuwayomiServerSources.parseListingId("popular-") == nil)
    }

    @Test func listingRequestBody() throws {
        let popular = try #require(SuwayomiServerSources.listingPayload(listingId: "popular-\(mangaDexEs)", page: 2))
        let body = try json(popular)
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["source"] as? String == mangaDexEs)
        #expect(variables["type"] as? String == "POPULAR")
        #expect(variables["page"] as? Int == 2)
        #expect(variables["query"] == nil || variables["query"] is NSNull)
        let query = try #require(body["query"] as? String)
        #expect(query.contains("mutation FetchSourceManga($source: LongString!, $type: FetchSourceMangaType!, $page: Int!, $query: String)"))
        #expect(query.contains("fetchSourceManga(input: {source: $source, type: $type, page: $page, query: $query})"))
        #expect(query.contains("hasNextPage"))
        for field in ["id", "title", "thumbnailUrl", "author", "artist", "inLibrary"] {
            #expect(query.contains(field))
        }

        let latest = try json(try #require(SuwayomiServerSources.listingPayload(listingId: "latest-\(mangaDexEs)", page: 1)))
        #expect((latest["variables"] as? [String: Any])?["type"] as? String == "LATEST")
        #expect(SuwayomiServerSources.listingPayload(listingId: "nope", page: 1) == nil)
    }

    // MARK: Search

    @Test func searchRequestBody() throws {
        let search = try json(SuwayomiServerSources.searchPayload(sourceId: mangaDexEs, query: "one piece", page: 3))
        let variables = try #require(search["variables"] as? [String: Any])
        #expect(variables["type"] as? String == "SEARCH")
        #expect(variables["query"] as? String == "one piece")
        #expect(variables["page"] as? Int == 3)
        #expect(variables["source"] as? String == mangaDexEs)

        for empty in [nil, "", "   "] as [String?] {
            let payload = SuwayomiServerSources.searchPayload(sourceId: mangaDexEs, query: empty, page: 1)
            #expect(payload.variables.type == .popular)
            #expect(payload.variables.query == nil)
        }
    }

    @Test func searchInFilter() throws {
        let es = source(id: mangaDexEs, name: "MangaDex (ES)", supportsLatest: true)
        let filter = try #require(SuwayomiServerSources.searchInFilter(sources: [es]))
        #expect(filter.id == "searchIn")
        #expect(filter.title == NSLocalizedString("SUWAYOMI_SEARCH_IN"))
        guard case let .select(select) = filter.value else {
            Issue.record("expected a select")
            return
        }
        #expect(select.options == [NSLocalizedString("SUWAYOMI_SEARCH_ALL"), NSLocalizedString("LIBRARY"), "MangaDex (ES)"])
        #expect(select.ids == ["", "library", mangaDexEs])
        #expect(!select.options[0].contains("SUWAYOMI_"))
        #expect(select.defaultValue == "")
        #expect(SuwayomiServerSources.searchInFilter(sources: []) == nil)

        #expect(SuwayomiServerSources.searchSourceId(filters: [.select(id: "searchIn", value: mangaDexEs)]) == mangaDexEs)
        #expect(SuwayomiServerSources.searchSourceId(filters: [.select(id: "searchIn", value: "")]) == nil)
        #expect(SuwayomiServerSources.searchSourceId(filters: [.select(id: "category", value: "3")]) == nil)
        #expect(SuwayomiServerSources.searchSourceId(filters: []) == nil)
    }

    // MARK: Responses

    @Test func decodesPopularPage() throws {
        let response = try JSONDecoder().decode(SuwayomiFetchSourceMangaResponse.self, from: fixture("fetch-source-manga-popular"))
        let page = SuwayomiServerSources.mangaPage(response, sourceKey: "suwayomi", baseUrl: baseUrl)
        #expect(page.entries.count == 9)
        #expect(!page.hasNextPage)
        let first = try #require(page.entries.first)
        #expect(first.sourceKey == "suwayomi")
        #expect(Int(first.key) != nil)
        #expect(first.title.hasPrefix("Zatsuyougakari"))
        #expect(first.cover?.hasPrefix("https://suwayomi.example:4567/api/v1/manga/") == true)
    }

    @Test func decodesLatestPageWithNextPage() throws {
        let response = try JSONDecoder().decode(SuwayomiFetchSourceMangaResponse.self, from: fixture("fetch-source-manga-latest"))
        let page = SuwayomiServerSources.mangaPage(response, sourceKey: "suwayomi", baseUrl: baseUrl)
        #expect(page.entries.count == 28)
        #expect(page.hasNextPage)
        #expect(page.entries.first?.title == "Zatch Bell! 2")
    }

    @Test func decodesSearchPage() throws {
        let response = try JSONDecoder().decode(SuwayomiFetchSourceMangaResponse.self, from: fixture("fetch-source-manga-search"))
        let page = SuwayomiServerSources.mangaPage(response, sourceKey: "suwayomi", baseUrl: baseUrl)
        #expect(page.entries.count == 20)
        #expect(page.hasNextPage)
        let first = try #require(page.entries.first)
        #expect(first.title == "One Piece")
        #expect(first.key == "33")
        #expect(first.authors == ["Oda Eiichirou (尾田栄一郎)"])
    }

    @Test func answersWithoutTheOptionalFieldsDecode() throws {
        let decoder = JSONDecoder()
        let state = try decoder.decode(SuwayomiMangaUpdateResponse.self, from: fixture("manga-update-state-only"))
        #expect(state.data.chapters == nil)
        #expect(state.chapterNodes.isEmpty)
        #expect(state.data.manga.title == nil)
        #expect(state.data.manga.initialized == true)
        // nothing asked for: nothing to fetch, even without chapters in the answer
        #expect(SuwayomiServerSources.remoteFetchPlan(state, needsDetails: false, needsChapters: false).isEmpty)
        let chapters = try decoder.decode(SuwayomiMangaUpdateResponse.self, from: fixture("manga-update-chapters-only"))
        #expect(chapters.chapterNodes.count == 26)
        #expect(chapters.data.manga.title == nil)
        // the newer answer only replaces what it was asked for
        let merged = state.updated(with: chapters, details: false, chapters: true)
        #expect(merged.chapterNodes.count == 26)
        #expect(merged.data.manga.initialized == true)
    }

    @Test func remoteFetchPlanUsesInitialized() throws {
        let decoder = JSONDecoder()
        let fresh = try decoder.decode(SuwayomiMangaUpdateResponse.self, from: fixture("manga-update-not-initialized"))
        #expect(fresh.data.manga.initialized == false)
        #expect(SuwayomiServerSources.remoteFetchPlan(fresh, needsDetails: true, needsChapters: true) == .init(fetchManga: true, fetchChapters: true))
        #expect(SuwayomiServerSources.remoteFetchPlan(fresh, needsDetails: true, needsChapters: false) == .init(fetchManga: true, fetchChapters: false))
        #expect(SuwayomiServerSources.remoteFetchPlan(fresh, needsDetails: false, needsChapters: false).isEmpty)

        // MangaDex manga come with an author even before being fetched: «initialized» decides, not the author
        let full = try decoder.decode(SuwayomiMangaUpdateResponse.self, from: fixture("manga-update-initialized"))
        #expect(full.data.manga.initialized == true)
        #expect(full.data.manga.author == "TYPE-MOON")
        #expect(!full.chapterNodes.isEmpty)
        #expect(SuwayomiServerSources.remoteFetchPlan(full, needsDetails: true, needsChapters: true).isEmpty)

        // details fetched but no chapters yet, outside the server library: only the chapters
        let noChaptersData = try fixture("manga-update-initialized-no-chapters")
        let noChapters = try decoder.decode(SuwayomiMangaUpdateResponse.self, from: noChaptersData)
        #expect(noChapters.chapterNodes.isEmpty)
        #expect(SuwayomiServerSources.remoteFetchPlan(noChapters, needsDetails: true, needsChapters: true) == .init(fetchManga: false, fetchChapters: true))
        #expect(SuwayomiServerSources.remoteFetchPlan(noChapters, needsDetails: true, needsChapters: false).isEmpty)

        // in the server library the server keeps the chapters updated itself: no remote fetch
        let inLibraryData = Data(String(decoding: noChaptersData, as: UTF8.self)
            .replacingOccurrences(of: "\"inLibrary\": false", with: "\"inLibrary\": true").utf8)
        let inLibrary = try decoder.decode(SuwayomiMangaUpdateResponse.self, from: inLibraryData)
        #expect(inLibrary.data.manga.inLibrary == true)
        #expect(SuwayomiServerSources.remoteFetchPlan(inLibrary, needsDetails: true, needsChapters: true).isEmpty)
    }

    @Test func searchTargetDefaultsToEverything() {
        let selected = [mangaDexEs]
        #expect(SuwayomiServerSources.searchTarget(filters: [], selectedIds: selected) == .all) // global search
        #expect(SuwayomiServerSources.searchTarget(filters: [.select(id: "searchIn", value: "")], selectedIds: selected) == .all)
        #expect(SuwayomiServerSources.searchTarget(filters: [.select(id: "searchIn", value: "library")], selectedIds: selected) == .library)
        #expect(SuwayomiServerSources.searchTarget(filters: [.select(id: "searchIn", value: mangaDexEs)], selectedIds: selected) == .source(mangaDexEs))
        // a source no longer selected → everything
        #expect(SuwayomiServerSources.searchTarget(filters: [.select(id: "searchIn", value: "999")], selectedIds: selected) == .all)
        #expect(SuwayomiServerSources.searchTarget(filters: [.select(id: "searchIn", value: mangaDexEs)], selectedIds: []) == .all)
        #expect(SuwayomiServerSources.libraryListing().id == "library")
        #expect(SuwayomiServerSources.libraryListing().name == NSLocalizedString("LIBRARY"))
    }

    @Test func searchSourcesFollowSettingOrderAndNsfw() throws {
        let known = try JSONDecoder().decode(SuwayomiSourcesResponse.self, from: fixture("sources-es")).data.sources.nodes
        let olympus = "1596411039134168890", emperor = "4562754350961964148", taurus = "5157867187592331768"
        let selected = [taurus, emperor, olympus, "0", "999"]
        #expect(SuwayomiServerSources.searchSources(selectedIds: selected, known: known, allowNsfw: true).map(\.id) == [olympus, emperor, taurus])
        #expect(SuwayomiServerSources.searchSources(selectedIds: selected, known: known, allowNsfw: false).map(\.id) == [olympus, taurus])
        #expect(SuwayomiServerSources.searchSources(selectedIds: [], known: known, allowNsfw: true).isEmpty)
    }

    @Test func everythingResultsKeepOrderWithoutDuplicates() {
        func manga(_ key: String) -> AidokuRunner.Manga { .init(sourceKey: "suwayomi", key: key, title: key) }
        let merged = SuwayomiServerSources.mergeSearchResults(
            library: [manga("156"), manga("7")],
            sources: [[manga("234"), manga("156")], [], [manga("343"), manga("234"), manga("344")]]
        )
        #expect(merged.map(\.key) == ["156", "7", "234", "343", "344"])
        #expect(SuwayomiServerSources.mergeSearchResults(library: [], sources: []).isEmpty)
    }

    @Test func noChaptersFoundIsRecognised() throws {
        let error = try #require(SuwayomiServerSources.graphQLError(from: fixture("fetch-chapters-no-chapters")))
        #expect(error == .message("No chapters found"))
        #expect(SuwayomiServerSources.isNoChaptersFound(error))
        #expect(!SuwayomiServerSources.isNoChaptersFound(SourceError.networkError))
        #expect(!SuwayomiServerSources.isNoChaptersFound(SourceError.message("Timeout")))
    }

    @Test func serverErrorsAreReadable() throws {
        let error = try #require(SuwayomiServerSources.graphQLError(from: fixture("fetch-source-manga-error")))
        guard case let .message(message) = error else {
            Issue.record("expected a message")
            return
        }
        #expect(!message.contains("Exception while fetching data"))
        #expect(!message.contains("java."))
        #expect(message == NSLocalizedString("SUWAYOMI_SERVER_ERROR"))
        #expect(message != "SUWAYOMI_SERVER_ERROR")

        #expect(SuwayomiServerSources.readableMessage(
            "Exception while fetching data (/fetchSourceManga) : HTTP error 503\r\n\r\njava.io.IOException: HTTP error 503"
        ) == "HTTP error 503")
        let okData = try fixture("fetch-source-manga-popular")
        #expect(SuwayomiServerSources.graphQLError(from: okData) == nil)
    }

    @Test func mutationBodies() throws {
        let fetchManga = try json(SuwayomiFetchMangaPayload(variables: .init(id: 54)))
        #expect((fetchManga["variables"] as? [String: Any])?["id"] as? Int == 54)
        #expect((fetchManga["query"] as? String)?.contains("fetchManga(input: {id: $id})") == true)

        let fetchChapters = try json(SuwayomiFetchChaptersPayload(variables: .init(mangaId: 54)))
        #expect((fetchChapters["variables"] as? [String: Any])?["mangaId"] as? Int == 54)
        #expect((fetchChapters["query"] as? String)?.contains("fetchChapters(input: {mangaId: $mangaId})") == true)

        let addToLibrary = try json(SuwayomiAddToLibraryPayload(variables: .init(id: 54)))
        #expect((addToLibrary["variables"] as? [String: Any])?["id"] as? Int == 54)
        #expect((addToLibrary["query"] as? String)?.contains("updateManga(input: {id: $id, patch: {inLibrary: true}})") == true)
    }
}
