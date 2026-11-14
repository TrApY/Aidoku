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

/// Fake Suwayomi GraphQL endpoint: answers by operation name, records calls.
final class SuwayomiFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: [Result<Data, Error>]] = [:]
    private var calls: [(operation: String, variables: [String: Any])] = []

    /// Queue of answers for an operation; the last one repeats.
    func respond(_ operation: String, _ results: Result<Data, Error>...) {
        lock.withLock { responses[operation] = results }
    }

    func count(_ operation: String) -> Int {
        lock.withLock { calls.filter { $0.operation == operation }.count }
    }

    func variables(_ operation: String) -> [[String: Any]] {
        lock.withLock { calls.filter { $0.operation == operation }.map(\.variables) }
    }

    var transport: SuwayomiHelper.Transport {
        { [self] request in try self.handle(request) }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = (body["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = query.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).dropFirst().first.map(String.init) ?? ""
        let result: Result<Data, Error> = lock.withLock {
            calls.append((operation, body["variables"] as? [String: Any] ?? [:]))
            guard var queue = responses[operation], let first = queue.first else {
                return .failure(URLError(.badServerResponse))
            }
            if queue.count > 1 {
                queue.removeFirst()
                responses[operation] = queue
            }
            return first
        }
        let data = try result.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Suite(.serialized) struct SuwayomiRunnerFlowTests {
    let key = "suwayomiflowtest"
    let server = SuwayomiFakeServer()

    private func makeRunner(selected: [String]? = nil) -> SuwayomiSourceRunner {
        let defaults = UserDefaults.standard
        defaults.set("https://suwayomi.example:4567", forKey: "\(key).server")
        if let selected {
            defaults.set(selected, forKey: "\(key).serverSources")
        } else {
            defaults.removeObject(forKey: "\(key).serverSources")
        }
        return SuwayomiSourceRunner(sourceKey: key, name: "Test", server: "https://suwayomi.example:4567", transport: server.transport)
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
        for searchIn in ["", "999"] { // «Biblioteca» and a source no longer selected
            let page = try await runner.getSearchMangaList(
                query: "guía",
                page: 1,
                filters: [.select(id: "searchIn", value: searchIn)]
            )
            #expect(page.entries.map(\.key) == ["156"])
        }
        #expect(server.count("SearchManga") == 2)
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
