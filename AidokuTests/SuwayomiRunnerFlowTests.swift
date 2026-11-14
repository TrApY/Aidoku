//
//  SuwayomiRunnerFlowTests.swift
//  AidokuTests
//
//  Flows of the built-in Suwayomi source runner against a fake GraphQL transport
//  answering with real responses recorded from a Suwayomi-Server v2.4 (Fixtures/Suwayomi).
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

private let mangaDexEs = "6400665728063187402"

/// Fake Suwayomi GraphQL endpoint: answers by operation name (and source, for
/// fetchSourceManga), records calls.
final class SuwayomiFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [Result<Data, Error>]] = [:]
    private var delays: [String: TimeInterval] = [:]
    private var calls: [(operation: String, variables: [String: Any])] = []

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
            calls.append((operation, variables))
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

@Suite(.serialized) struct SuwayomiRunnerFlowTests {
    let key = "suwayomiflowtest"
    let server = SuwayomiFakeServer()

    private func makeRunner(selected: [String]? = nil, searchAllTimeout: TimeInterval = 20) -> SuwayomiSourceRunner {
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
            searchAllTimeout: searchAllTimeout
        )
    }

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: "\(key).server")
        UserDefaults.standard.removeObject(forKey: "\(key).serverSources")
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

    @Test func failedRemoteFetchReturnsWhatTheServerHas() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-initialized-no-chapters")))
        server.respond("FetchChapters", .failure(URLError(.timedOut)))
        let runner = makeRunner()
        let manga = try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "35", title: "x"),
            needsDetails: true,
            needsChapters: true
        )
        #expect(manga.title == "One Piece Omake")
        #expect(manga.description?.isEmpty == false)
        #expect(manga.chapters?.isEmpty == true)
        #expect(server.count("FetchManga") == 0)
        #expect(server.count("FetchChapters") == 1)
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
}
