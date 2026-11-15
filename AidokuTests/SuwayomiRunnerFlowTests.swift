//
//  SuwayomiRunnerFlowTests.swift
//  AidokuTests
//
//  Flows of the built-in Suwayomi source runner against a fake GraphQL transport
//  answering with real responses recorded from a Suwayomi-Server v2.4 (Fixtures/Suwayomi).
//

import AidokuRunner
import CoreData
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

private let mangaDexEs = "6400665728063187402"

/// Fake Suwayomi GraphQL endpoint: answers by operation name (and source, for
/// fetchSourceManga), records calls.
final class SuwayomiFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [Result<Data, Error>]] = [:]
    private var delays: [String: TimeInterval] = [:]
    private var calls: [(operation: String, variables: [String: Any], timeout: TimeInterval)] = []

    /// Queue of answers for an operation; the last one repeats.
    func respond(_ operation: String, source: String? = nil, delay: TimeInterval = 0, _ results: Result<Data, Error>...) {
        let key = source.map { "\(operation)|\($0)" } ?? operation
        lock.withLock {
            responses[key] = results
            delays[key] = delay
        }
    }

    func count(_ operation: String) -> Int {
        lock.withLock { calls.filter { $0.operation == operation }.count }
    }

    func variables(_ operation: String) -> [[String: Any]] {
        lock.withLock { calls.filter { $0.operation == operation }.map(\.variables) }
    }

    func timeouts(_ operation: String) -> [TimeInterval] {
        lock.withLock { calls.filter { $0.operation == operation }.map(\.timeout) }
    }

    var transport: SuwayomiHelper.Transport {
        { [self] request in
            let (result, delay) = self.answer(request)
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let data = try result.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    private func answer(_ request: URLRequest) -> (Result<Data, Error>, TimeInterval) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = (body["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = query.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).dropFirst().first.map(String.init) ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        return lock.withLock {
            calls.append((operation, variables, request.timeoutInterval))
            let sourceKey = (variables["source"] as? String).map { "\(operation)|\($0)" }
            let key = sourceKey.flatMap { responses[$0] != nil ? $0 : nil } ?? operation
            guard var queue = responses[key], let first = queue.first else {
                return (.failure(URLError(.badServerResponse)), 0)
            }
            if queue.count > 1 {
                queue.removeFirst()
                responses[key] = queue
            }
            return (first, delays[key] ?? 0)
        }
    }
}

private let olympus = "1596411039134168890"
private let emperor = "4562754350961964148"
private let taurus = "5157867187592331768"
private let nexus = "4086183896761281232" // flagged NSFW

@Suite(.serialized) struct SuwayomiRunnerFlowTests {
    let key = "suwayomiflowtest"
    let server = SuwayomiFakeServer()

    private func makeRunner(
        selected: [String]? = nil,
        searchAllTimeout: TimeInterval = 20,
        serverSourcesMaxAge: TimeInterval = 5 * 60,
        filterCacheMaxAge: TimeInterval = 10 * 60
    ) -> SuwayomiSourceRunner {
        let defaults = UserDefaults.standard
        defaults.set("https://suwayomi.example:4567", forKey: "\(key).server")
        if let selected {
            defaults.set(selected, forKey: "\(key).serverSources")
        } else {
            defaults.removeObject(forKey: "\(key).serverSources")
        }
        return SuwayomiSourceRunner(
            sourceKey: key,
            name: "Test",
            server: "https://suwayomi.example:4567",
            transport: server.transport,
            searchAllTimeout: searchAllTimeout,
            serverSourcesMaxAge: serverSourcesMaxAge,
            filterCacheMaxAge: filterCacheMaxAge
        )
    }

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: "\(key).server")
        UserDefaults.standard.removeObject(forKey: "\(key).serverSources")
        UserDefaults.standard.removeObject(forKey: "\(key).serverSourcesSnapshot")
    }

    // MARK: Listings

    @Test func emptySettingListsOnlyTheLibrary() async throws {
        defer { cleanUp() }
        let runner = makeRunner()
        let listings = try await runner.getListings()
        #expect(listings.map(\.id) == ["library"])
        #expect(listings.first?.name == NSLocalizedString("LIBRARY"))
        #expect(server.count("GetServerSources") == 0)
    }

    @Test func selectedSourcesComeAfterTheLibrary() async throws {
        defer { cleanUp() }
        server.respond("GetServerSources", .success(try fixture("sources")))
        let runner = makeRunner(selected: [mangaDexEs])
        let listings = try await runner.getListings()
        #expect(listings.map(\.id) == ["library", "popular-\(mangaDexEs)", "latest-\(mangaDexEs)"])
    }

    @Test func unreachableServerStillListsTheLibrary() async throws {
        defer { cleanUp() }
        server.respond("GetServerSources", .failure(URLError(.timedOut)))
        let runner = makeRunner(selected: [mangaDexEs])
        let listings = try await runner.getListings()
        #expect(listings.map(\.id) == ["library"])
        #expect(server.count("GetServerSources") == 1)
    }

    @Test func libraryListingShowsTheServerLibrary() async throws {
        defer { cleanUp() }
        server.respond("SearchManga", .success(try fixture("library-search")))
        let runner = makeRunner()
        let page = try await runner.getMangaList(listing: SuwayomiServerSources.libraryListing(), page: 1)
        #expect(page.entries.map(\.key) == ["156"])
        #expect(page.entries.first?.title == "Guía De Supervivencia Del Cazador De Bestias Demoníacas")
        #expect(!page.hasNextPage)
        let variables = try #require(server.variables("SearchManga").first)
        #expect(variables["filter"] == nil || variables["filter"] is NSNull)

        // same as the library search without text nor filters
        let search = try await runner.getSearchMangaList(query: nil, page: 1, filters: [])
        #expect(search.entries.map(\.key) == page.entries.map(\.key))
        #expect(server.count("FetchSourceManga") == 0)
    }

    // MARK: Search

    @Test func searchGoesToTheChosenServerSource() async throws {
        defer { cleanUp() }
        server.respond("FetchSourceManga", .success(try fixture("fetch-source-manga-search")))
        let runner = makeRunner(selected: [mangaDexEs])
        let page = try await runner.getSearchMangaList(
            query: "one piece",
            page: 1,
            filters: [.select(id: "searchIn", value: mangaDexEs), .select(id: "category", value: "3")]
        )
        #expect(page.entries.first?.title == "One Piece")
        #expect(page.hasNextPage)
        let variables = try #require(server.variables("FetchSourceManga").first)
        #expect(variables["type"] as? String == "SEARCH")
        #expect(variables["source"] as? String == mangaDexEs)
        #expect(server.count("SearchManga") == 0)
    }

    @Test func librarySearchStaysTheSame() async throws {
        defer { cleanUp() }
        server.respond("SearchManga", .success(try fixture("library-search")))
        let runner = makeRunner(selected: [mangaDexEs])
        let page = try await runner.getSearchMangaList(
            query: "guía",
            page: 1,
            filters: [.select(id: "searchIn", value: "library"), .select(id: "category", value: "3")]
        )
        #expect(page.entries.map(\.key) == ["156"])
        #expect(server.count("SearchManga") == 1)
        #expect(server.count("FetchSourceManga") == 0)
        let variables = try #require(server.variables("SearchManga").first)
        #expect(variables["filter"] is [String: Any])
    }

    // MARK: Search everything

    private func respondSpanishSources() throws {
        server.respond("GetServerSources", .success(try fixture("sources-es")))
        server.respond("SearchManga", .success(try fixture("library-search")))
        server.respond("FetchSourceManga", source: olympus, .success(try fixture("fetch-source-manga-olympus-search")))
        server.respond("FetchSourceManga", source: emperor, .success(try fixture("fetch-source-manga-emperor-search")))
        server.respond("FetchSourceManga", source: taurus, .success(try fixture("fetch-source-manga-taurus-search")))
    }

    @Test func everythingSearchesLibraryAndSelectedSources() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        // chosen in another order than the setting's: results follow the setting (Olympus, Emperor, Taurus)
        let runner = makeRunner(selected: [taurus, emperor, olympus])
        for filters in [[], [AidokuRunner.FilterValue.select(id: "searchIn", value: "")]] {
            let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: filters)
            let keys = page.entries.map(\.key)
            try #require(keys.count == 1 + 10 + 25) // Emperor only returns 156, already in the library
            #expect(keys.first == "156")
            #expect(Array(keys[1...10]) == (234...243).map(String.init))
            #expect(keys[11] == "343")
            #expect(Set(keys).count == keys.count)
            #expect(!page.hasNextPage)
        }
        let searched = server.variables("FetchSourceManga")
        #expect(searched.count == 6)
        #expect(searched.allSatisfy { $0["type"] as? String == "SEARCH" && $0["query"] as? String == "solo" && $0["page"] as? Int == 1 })
        #expect(server.count("SearchManga") == 2)
    }

    @Test func everythingUsesTheCachedSourceList() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus, taurus])
        _ = try await runner.getListings() // the source list is now known
        #expect(server.count("GetServerSources") == 1)
        server.respond("GetServerSources", delay: 3, .success(try fixture("sources-es")))
        let start = Date()
        let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(Date().timeIntervalSince(start) < 1.5) // no wait for the source list before searching
        #expect(page.entries.count == 1 + 10 + 25)
        #expect(server.count("GetServerSources") == 1)
    }

    @Test func everythingWithoutAnswerUsesTheStoredListInSettingsOrder() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        _ = try await makeRunner(selected: [taurus, emperor, olympus]).getListings()
        // app relaunched (no list in memory) and the server doesn't list its sources now
        server.respond("GetServerSources", .failure(URLError(.timedOut)))
        let runner = makeRunner(selected: [taurus, emperor, olympus])
        let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        let keys = page.entries.map(\.key)
        try #require(keys.count == 1 + 10 + 25)
        #expect(keys[1] == "234") // Olympus before Taurus, as in the settings
        #expect(keys[11] == "343")
        await runner.waitForServerSourcesRefresh()
    }

    // MARK: Source list cache

    @Test func concurrentSearchesRefreshTheListOnce() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus, taurus], serverSourcesMaxAge: 0) // always old
        _ = try await runner.getListings()
        server.respond("GetServerSources", delay: 0.5, .success(try fixture("sources-es")))
        async let first = runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        async let second = runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        let results = try await [first, second]
        #expect(results.allSatisfy { $0.entries.count == 1 + 10 + 25 })
        await runner.waitForServerSourcesRefresh()
        #expect(server.count("GetServerSources") == 2) // listings + one background refresh
    }

    @Test func listIsRefreshedOnceItExpires() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus], serverSourcesMaxAge: 0.3)
        _ = try await runner.getListings()
        _ = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        await runner.waitForServerSourcesRefresh()
        #expect(server.count("GetServerSources") == 1) // still fresh
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        await runner.waitForServerSourcesRefresh()
        #expect(server.count("GetServerSources") == 2)
    }

    @Test func failedRefreshCoolsDown() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus], serverSourcesMaxAge: 0)
        _ = try await runner.getListings()
        server.respond("GetServerSources", .failure(URLError(.timedOut)))
        for _ in 0..<3 {
            let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
            #expect(page.entries.count == 11) // the known list keeps working
            await runner.waitForServerSourcesRefresh()
        }
        #expect(server.count("GetServerSources") == 2) // listings + one failed refresh, then cooling down
    }

    @Test func unknownListCoolsDownAfterFailing() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        server.respond("GetServerSources", delay: 0.5, .failure(URLError(.timedOut)))
        let runner = makeRunner(selected: [olympus])
        _ = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        let start = Date()
        for _ in 0..<2 {
            let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
            #expect(page.entries.map(\.key) == ["156"]) // only the library, as before
        }
        #expect(Date().timeIntervalSince(start) < 0.4) // no new wait for the list
        #expect(server.count("GetServerSources") == 1)
    }

    @Test func serverChangeForgetsTheListAndTheMarks() async throws {
        defer {
            cleanUp()
            TrackerManager.suwayomi.markedInLibrary.removeAll(withPrefix: "suwayomiotherserver|")
        }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus])
        _ = try await runner.getListings()
        #expect(UserDefaults.standard.data(forKey: "\(key).serverSourcesSnapshot") != nil)
        TrackerManager.suwayomi.markedInLibrary.insert("\(key)|56")
        TrackerManager.suwayomi.markedInLibrary.insert("suwayomiotherserver|56")

        UserDefaults.standard.set("https://otro.example:4567", forKey: "\(key).server")
        try await runner.handleNotification(notification: "server_change")

        #expect(UserDefaults.standard.data(forKey: "\(key).serverSourcesSnapshot") == nil)
        #expect(!TrackerManager.suwayomi.markedInLibrary.contains("\(key)|56"))
        #expect(TrackerManager.suwayomi.markedInLibrary.contains("suwayomiotherserver|56"))
        // the old list isn't used for the new server
        server.respond("GetServerSources", .failure(URLError(.timedOut)))
        let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(page.entries.map(\.key) == ["156"])
        #expect(server.count("FetchSourceManga") == 0)
    }

    @Test func hiddenNsfwSourcesAreNotSearched() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        server.respond("FetchSourceManga", source: nexus, .success(try fixture("fetch-source-manga-nexus-search")))
        let ratings = AppSettings.browse.contentRatings.get()
        defer { AppSettings.browse.contentRatings.set(ratings) }

        AppSettings.browse.contentRatings.set([.safe, .containsNsfw])
        let shown = try await makeRunner(selected: [olympus, nexus]).getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(shown.entries.count == 1 + 10 + 20)
        #expect(shown.entries.contains { $0.key == "244" })

        AppSettings.browse.contentRatings.set([.safe])
        let hidden = try await makeRunner(selected: [olympus, nexus]).getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(hidden.entries.count == 1 + 10)
        #expect(!hidden.entries.contains { $0.key == "244" })
        #expect(server.variables("FetchSourceManga").filter { $0["source"] as? String == nexus }.count == 1)
    }

    @Test func everythingSkipsFailingAndSlowSources() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        server.respond("FetchSourceManga", source: olympus, .success(try fixture("fetch-source-manga-error")))
        server.respond("FetchSourceManga", source: taurus, delay: 5, .success(try fixture("fetch-source-manga-taurus-search")))
        let runner = makeRunner(selected: [olympus, emperor, taurus], searchAllTimeout: 0.5)
        let start = Date()
        let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(page.entries.map(\.key) == ["156"])
    }

    @Test func everythingWithoutSelectedSourcesIsTheLibrary() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner()
        let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(page.entries.map(\.key) == ["156"])
        #expect(server.count("FetchSourceManga") == 0)
        #expect(server.count("GetServerSources") == 0)
    }

    @Test func staleSearchSourceSearchesEverything() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus])
        let page = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [.select(id: "searchIn", value: "999")])
        #expect(page.entries.count == 11)
        #expect(server.variables("FetchSourceManga").map { $0["source"] as? String } == [olympus])
    }

    @Test func everythingWithoutTextIsTheLibraryAndListingStaysLibrary() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [olympus, taurus])
        let search = try await runner.getSearchMangaList(query: nil, page: 1, filters: [])
        let listing = try await runner.getMangaList(listing: SuwayomiServerSources.libraryListing(), page: 1)
        #expect(search.entries.map(\.key) == ["156"])
        #expect(listing.entries.map(\.key) == ["156"])
        #expect(server.count("FetchSourceManga") == 0)
    }

    // MARK: Manga update

    @Test func initializedMangaIsReadWithoutRemoteFetch() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-initialized")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "x"),
            needsDetails: true,
            needsChapters: true
        )
        #expect(manga.chapters?.count == 26)
        #expect(manga.authors == ["TYPE-MOON"])
        #expect(server.count("FetchManga") == 0)
        #expect(server.count("FetchChapters") == 0)
    }

    @Test func notInitializedMangaIsFetchedFromTheOrigin() async throws {
        defer { cleanUp() }
        server.respond(
            "GetMangaUpdate",
            .success(try fixture("manga-update-not-initialized")),
            .success(try fixture("manga-update-initialized"))
        )
        server.respond("FetchManga", .success(try fixture("fetch-manga")))
        server.respond("FetchChapters", .success(try fixture("fetch-chapters")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "56", title: "x"),
            needsDetails: true,
            needsChapters: true
        )
        #expect(server.count("FetchManga") == 1)
        #expect(server.count("FetchChapters") == 1)
        #expect(server.count("GetMangaUpdate") == 2)
        #expect(manga.chapters?.count == 26)
    }

    @Test func failedChapterFetchIsAnError() async throws {
        defer { cleanUp() }
        // initialized, outside the server library, no chapters stored: a network failure is not «no chapters»
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-initialized-no-chapters")))
        server.respond("FetchChapters", .failure(URLError(.timedOut)))
        let runner = makeRunner()
        await #expect(throws: SourceError.self) {
            _ = try await runner.getMangaUpdate(
                manga: .init(sourceKey: key, key: "35", title: "x"),
                needsDetails: true,
                needsChapters: true
            )
        }
        #expect(server.count("FetchChapters") == 1)

        // details only: nothing to fetch, what the server has
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "35", title: "x"),
            needsDetails: true,
            needsChapters: false
        )
        #expect(manga.title == "One Piece Omake")
        #expect(server.count("FetchChapters") == 1)
        #expect(server.count("FetchManga") == 0)
    }

    @Test func failedDetailsFetchKeepsStoredChapters() async throws {
        defer { cleanUp() }
        let stored = String(decoding: try fixture("manga-update-initialized"), as: UTF8.self)
            .replacingOccurrences(of: "\"initialized\": true", with: "\"initialized\": false")
        server.respond("GetMangaUpdate", .success(Data(stored.utf8)))
        server.respond("FetchManga", .failure(URLError(.timedOut)))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "x"),
            needsDetails: true,
            needsChapters: true
        )
        #expect(manga.chapters?.count == 26)
        #expect(server.count("FetchManga") == 1)
        #expect(server.count("FetchChapters") == 0)
    }

    @Test func noChaptersFoundIsAnEmptyList() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-initialized-no-chapters")))
        server.respond("FetchChapters", .success(try fixture("fetch-chapters-no-chapters")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "35", title: "x"),
            needsDetails: true,
            needsChapters: true
        )
        #expect(manga.chapters?.isEmpty == true)
    }

    @Test func failedRemoteFetchWithNothingStoredThrows() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-not-initialized")))
        server.respond("FetchManga", .success(try fixture("fetch-source-manga-error")))
        server.respond("FetchChapters", .failure(URLError(.timedOut)))
        let runner = makeRunner()
        await #expect(throws: SourceError.self) {
            _ = try await runner.getMangaUpdate(
                manga: .init(sourceKey: key, key: "56", title: "x"),
                needsDetails: true,
                needsChapters: true
            )
        }
    }

    // MARK: Audit (SUWA-9)

    @Test func detailsOnlyDoesNotAskForChapters() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-initialized")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "x"),
            needsDetails: true,
            needsChapters: false
        )
        #expect(manga.authors == ["TYPE-MOON"])
        #expect(manga.chapters == nil)
        let variables = server.variables("GetMangaUpdate")
        #expect(variables.count == 1)
        #expect(variables.first?["details"] as? Bool == true)
        #expect(variables.first?["chapters"] as? Bool == false)
    }

    @Test func noSecondFullQueryWhenNothingNeededWasFetched() async throws {
        defer { cleanUp() }
        // details never fetched, chapters stored: chapters asked for, so the server fetches the details,
        // but nothing asked for changed: no second query
        let stored = String(decoding: try fixture("manga-update-initialized"), as: UTF8.self)
            .replacingOccurrences(of: "\"initialized\": true", with: "\"initialized\": false")
        server.respond("GetMangaUpdate", .success(Data(stored.utf8)))
        server.respond("FetchManga", .success(try fixture("fetch-manga")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "x"),
            needsDetails: false,
            needsChapters: true
        )
        #expect(manga.chapters?.count == 26)
        #expect(server.count("FetchManga") == 1)
        #expect(server.count("GetMangaUpdate") == 1)
        #expect(server.variables("GetMangaUpdate").first?["details"] as? Bool == false)
    }

    @Test func secondQueryAsksOnlyForWhatWasFetched() async throws {
        defer { cleanUp() }
        server.respond(
            "GetMangaUpdate",
            .success(try fixture("manga-update-not-initialized")),
            .success(try fixture("manga-update-initialized"))
        )
        server.respond("FetchManga", .success(try fixture("fetch-manga")))
        server.respond("FetchChapters", .success(try fixture("fetch-chapters")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "56", title: "x"),
            needsDetails: false,
            needsChapters: true
        )
        #expect(manga.chapters?.count == 26)
        let variables = server.variables("GetMangaUpdate")
        #expect(variables.count == 2)
        #expect(variables.last?["details"] as? Bool == false)
        #expect(variables.last?["chapters"] as? Bool == true)
    }

    private func respondFilterData() {
        server.respond("GetCategories", .success(Data(#"{"data":{"categories":{"nodes":[{"id":0,"name":"Default"},{"id":3,"name":"Leyendo"}]}}}"#.utf8)))
        server.respond("GetMangaTags", .success(Data(#"{"data":{"mangas":{"nodes":[{"genre":["Acción","Drama"]},{"genre":["Acción"]}]}}}"#.utf8)))
    }

    @Test func filtersAskForCategoriesAndTagsOnce() async throws {
        defer { cleanUp() }
        respondFilterData()
        let runner = makeRunner()
        let first = try await runner.getSearchFilters()
        let second = try await runner.getSearchFilters()
        #expect(first.map(\.id) == second.map(\.id))
        #expect(server.count("GetMangaTags") == 1)
        #expect(server.count("GetCategories") == 1)

        // a new server: asked again
        UserDefaults.standard.set("https://otro.example:4567", forKey: "\(key).server")
        try await runner.handleNotification(notification: "server_change")
        _ = try await runner.getSearchFilters()
        #expect(server.count("GetMangaTags") == 2)
        #expect(server.count("GetCategories") == 2)
    }

    @Test func filterDataIsAskedAgainWhenOld() async throws {
        defer { cleanUp() }
        respondFilterData()
        let runner = makeRunner(filterCacheMaxAge: 0)
        _ = try await runner.getSearchFilters()
        _ = try await runner.getSearchFilters()
        #expect(server.count("GetMangaTags") == 2)
    }

    @Test func searchingOneSourceWaitsThirtySeconds() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        server.respond("FetchSourceManga", source: olympus, .success(try fixture("fetch-source-manga-olympus-search")))
        let runner = makeRunner(selected: [olympus])
        _ = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [.select(id: "searchIn", value: olympus)])
        #expect(server.timeouts("FetchSourceManga") == [30])
    }

    @Test func stateOnlyAnswerIsEnough() async throws {
        defer { cleanUp() }
        // real answer with details and chapters left out by @include: only the state fields
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-state-only")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "Guardado"),
            needsDetails: false,
            needsChapters: false
        )
        #expect(manga.title == "Guardado")
        #expect(manga.chapters == nil)
        #expect(server.count("FetchManga") == 0)
        #expect(server.count("FetchChapters") == 0)
    }

    @Test func chaptersOnlyAnswerKeepsTheDetails() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-chapters-only")))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "Guardado", authors: ["Autor"]),
            needsDetails: false,
            needsChapters: true
        )
        #expect(manga.title == "Guardado")
        #expect(manga.authors == ["Autor"])
        #expect(manga.chapters?.count == 26)
        #expect(server.count("GetMangaUpdate") == 1)
    }

    // MARK: Grouped search (global search rows)

    @Test func groupedSearchGivesTheLibraryAndOneSectionPerSourceInSettingsOrder() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [taurus, emperor, olympus])
        let sections = try await runner.groupedSearch(query: "solo")
        try #require(sections.count == 4)
        #expect(sections.map(\.id) == ["library", olympus, emperor, taurus])
        #expect(sections[0].entries.map(\.key) == ["156"])
        #expect(sections[0].title.contains("Test")) // «Biblioteca (<source name>)»
        #expect(sections[0].iconUrl == nil)
        #expect(sections[1].entries.map(\.key) == (234...243).map(String.init))
        #expect(sections[1].title == "Olympus Scanlation (ES)")
        #expect(sections[1].iconUrl == URL(string: "https://suwayomi.example:4567/api/v1/extension/icon/eu.kanade.tachiyomi.extension.es.olympusscanlation"))
        #expect(sections[2].entries.map(\.key) == ["156"]) // also in its own source
        #expect(sections[3].entries.count == 25)
        #expect(sections.allSatisfy { $0.entries.allSatisfy { $0.sourceKey == key } })
    }

    @Test func groupedSearchLeavesOutFailingSourcesAndAnEmptyLibrary() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        server.respond("SearchManga", .success(Data(#"{"data":{"mangas":{"nodes":[]}}}"#.utf8)))
        server.respond("FetchSourceManga", source: emperor, .failure(URLError(.timedOut)))
        let runner = makeRunner(selected: [olympus, emperor, taurus])
        let sections = try await runner.groupedSearch(query: "solo")
        #expect(sections.map(\.id) == [olympus, taurus])
        // a source with no results keeps its section (the row shows nothing, as any other source)
        server.respond("FetchSourceManga", source: taurus, .success(Data(#"{"data":{"fetchSourceManga":{"mangas":[],"hasNextPage":false}}}"#.utf8)))
        let again = try await runner.groupedSearch(query: "solo")
        #expect(again.map(\.id) == [olympus, taurus])
        #expect(again.last?.entries.isEmpty == true)
    }

    @Test func groupedSearchWithoutSourcesIsTheLibrary() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner(selected: [])
        let sections = try await runner.groupedSearch(query: "solo")
        #expect(sections.map(\.id) == ["library"])
        #expect(server.count("FetchSourceManga") == 0)
    }

    @Test func serverSourceOfAManga() async throws {
        defer { cleanUp() }
        server.respond("GetMangaSource", .success(Data(#"{"data":{"manga":{"sourceId":"1596411039134168890"}}}"#.utf8)))
        let runner = makeRunner()
        #expect(await runner.serverSourceId(ofMangaKey: "753") == olympus)
        #expect(server.variables("GetMangaSource").first?["id"] as? Int == 753)
        server.respond("GetMangaSource", .failure(URLError(.timedOut)))
        #expect(await runner.serverSourceId(ofMangaKey: "753") == nil)
        #expect(await runner.serverSourceId(ofMangaKey: "no") == nil)
    }
}

@Suite(.serialized) struct SuwayomiTrackerLibraryTests {
    let key = "suwayomitrackertest"
    let server = SuwayomiFakeServer()

    private let notInLibrary = Data(#"{"data":{"manga":{"inLibrary":false}}}"#.utf8)
    private let added = Data(#"{"data":{"updateManga":{"manga":{"id":56,"inLibrary":true}}}}"#.utf8)

    private func makeTracker() -> SuwayomiTracker {
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(key).server")
        return SuwayomiTracker(api: SuwayomiApi(transport: server.transport))
    }

    @Test func serverLibraryIsMarkedOnlyOnce() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        server.respond("GetInLibrary", .success(notInLibrary))
        server.respond("AddToServerLibrary", .success(added))
        let tracker = makeTracker()
        _ = try await tracker.register(trackId: "\(key)|56", highestChapterRead: nil, earliestReadDate: nil)
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate())
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate())
        #expect(server.count("GetInLibrary") == 1)
        #expect(server.count("AddToServerLibrary") == 1)

        // another manga is still checked
        try await tracker.update(trackId: "\(key)|57", update: TrackUpdate())
        #expect(server.count("GetInLibrary") == 2)
    }

    @Test func failedMarkIsRetried() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        server.respond("GetInLibrary", .failure(URLError(.timedOut)), .success(notInLibrary))
        server.respond("AddToServerLibrary", .success(added))
        let tracker = makeTracker()
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate()) // fails, logged
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate()) // retried, marked
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate()) // remembered
        #expect(server.count("GetInLibrary") == 2)
        #expect(server.count("AddToServerLibrary") == 1)
    }

    @Test func markingReadAsksOnlyForUnreadChaptersUpToTheNumber() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        server.respond("GetInLibrary", .success(Data(#"{"data":{"manga":{"inLibrary":true}}}"#.utf8)))
        server.respond(
            "GetChaptersForTrackUpdate",
            .success(Data(#"{"data":{"chapters":{"nodes":[{"id":11,"chapterNumber":1},{"id":12,"chapterNumber":2}]}}}"#.utf8)),
            .success(Data(#"{"data":{"chapters":{"nodes":[]}}}"#.utf8))
        )
        server.respond("MarkChaptersRead", .success(Data(#"{"data":{"updateChapters":{"chapters":[{"id":11},{"id":12}]}}}"#.utf8)))
        let tracker = makeTracker()
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate(lastReadChapter: 2.5))
        let asked = server.variables("GetChaptersForTrackUpdate")
        #expect(asked.first?["below"] as? Double == 3) // chapters numbered below 3 (floor ≤ 2.5)
        #expect(server.variables("MarkChaptersRead").first?["ids"] as? [Int] == [11, 12])
        // everything up to there already read on the server: no mutation
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate(lastReadChapter: 2))
        #expect(server.count("MarkChaptersRead") == 1)
    }

    @Test func logoutForgetsTrackedMangaWithoutCrashing() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        let tracker = makeTracker()
        let mangaId = MangaIdentifier(sourceKey: key, mangaKey: "77")
        await CoreDataManager.shared.container.performBackgroundTask { context in
            _ = CoreDataManager.shared.createTrack(id: "\(self.key)|77", trackerId: tracker.id, mangaId: mangaId, title: nil, context: context)
            try? context.save()
        }
        await tracker.logout()
        let left = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.hasTrack(trackerId: tracker.id, mangaId: mangaId, context: context)
        }
        #expect(!left)
    }

    @Test func markingReadWithRepeatedAndDecimalNumbers() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        server.respond("GetInLibrary", .success(Data(#"{"data":{"manga":{"inLibrary":true}}}"#.utf8)))
        // the server filters by number < 11; 11 is in the answer only to check the app's own filter
        server.respond(
            "GetChaptersForTrackUpdate",
            .success(Data(#"{"data":{"chapters":{"nodes":[{"id":1,"chapterNumber":10},{"id":2,"chapterNumber":10},{"id":3,"chapterNumber":10.5},{"id":4,"chapterNumber":11},{"id":5,"chapterNumber":9.9}]}}}"#.utf8))
        )
        server.respond("MarkChaptersRead", .success(Data(#"{"data":{"updateChapters":{"chapters":[]}}}"#.utf8)))
        let tracker = makeTracker()
        try await tracker.update(trackId: "\(key)|56", update: TrackUpdate(lastReadChapter: 10))
        #expect(server.variables("GetChaptersForTrackUpdate").first?["below"] as? Double == 11)
        // as before: every chapter whose whole number is ≤ 10 (both 10s and 10.5), not 11
        #expect(server.variables("MarkChaptersRead").first?["ids"] as? [Int] == [1, 2, 3, 5])
    }
}
