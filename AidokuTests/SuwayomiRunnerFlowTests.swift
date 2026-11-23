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

/// Records the requests sent through a transport (URL and headers).
final class SuwayomiRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var all: [URLRequest] { lock.withLock { requests } }

    func recording(_ transport: @escaping SuwayomiHelper.Transport) -> SuwayomiHelper.Transport {
        { [self] request in
            self.lock.withLock { self.requests.append(request) }
            return try await transport(request)
        }
    }
}

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

    private var inFlight: [String: Int] = [:]
    private var maxInFlightByOperation: [String: Int] = [:]

    /// Most requests of an operation that were waiting for an answer at the same time.
    func maxInFlight(_ operation: String) -> Int {
        lock.withLock { maxInFlightByOperation[operation] ?? 0 }
    }

    var transport: SuwayomiHelper.Transport {
        { [self] request in
            let (result, delay) = self.answer(request)
            let operation = Self.operation(of: request)
            self.lock.withLock {
                self.inFlight[operation, default: 0] += 1
                self.maxInFlightByOperation[operation] = max(self.maxInFlightByOperation[operation] ?? 0, self.inFlight[operation] ?? 0)
            }
            defer { self.lock.withLock { self.inFlight[operation, default: 1] -= 1 } }
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let data = try result.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    static func operation(of request: URLRequest) -> String {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let query = (body["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return query.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "{" }).dropFirst().first.map(String.init) ?? ""
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
    let key = "suwayomi.flowtest"
    let server = SuwayomiFakeServer()

    private func makeRunner(filterCacheMaxAge: TimeInterval = 10 * 60) -> SuwayomiSourceRunner {
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(key).server")
        return SuwayomiSourceRunner(
            sourceKey: key,
            name: "Test",
            server: "https://suwayomi.example:4567",
            transport: server.transport,
            filterCacheMaxAge: filterCacheMaxAge
        )
    }

    /// A server source of the connection `key` (its listings and search only cover it).
    private func makeChild(_ serverSourceId: String, supportsLatest: Bool = true, limiter: SuwayomiSearchLimiter? = nil) -> SuwayomiSourceRunner {
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(key).server")
        let config = SuwayomiServerSourceConfig(
            key: SuwayomiServerSourceConfig.key(parentKey: key, serverSourceId: serverSourceId),
            parentKey: key, serverSourceId: serverSourceId, name: "Fuente", lang: "es", iconUrl: "",
            isNsfw: false, supportsLatest: supportsLatest, available: true
        )
        SuwayomiConnections.shared.register(child: config)
        return SuwayomiSourceRunner(
            sourceKey: config.key, name: config.name, server: "", serverSource: config,
            transport: server.transport, searchLimiter: limiter
        )
    }

    private func cleanUp() {
        UserDefaults.standard.removeObject(forKey: "\(key).server")
        for child in SuwayomiConnections.shared.children(of: key) {
            SuwayomiConnections.shared.unregister(child.key)
        }
    }

    // MARK: Listings

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

    @Test func librarySearchStaysTheSame() async throws {
        defer { cleanUp() }
        server.respond("SearchManga", .success(try fixture("library-search")))
        let runner = makeRunner()
        let page = try await runner.getSearchMangaList(
            query: "guía",
            page: 1,
            filters: [.select(id: "category", value: "3")]
        )
        #expect(page.entries.map(\.key) == ["156"])
        #expect(server.count("SearchManga") == 1)
        #expect(server.count("FetchSourceManga") == 0)
        let variables = try #require(server.variables("SearchManga").first)
        #expect(variables["filter"] is [String: Any])
    }

    private func respondSpanishSources() throws {
        server.respond("GetServerSources", .success(try fixture("sources-es")))
        server.respond("SearchManga", .success(try fixture("library-search")))
        server.respond("FetchSourceManga", source: olympus, .success(try fixture("fetch-source-manga-olympus-search")))
        server.respond("FetchSourceManga", source: emperor, .success(try fixture("fetch-source-manga-emperor-search")))
        server.respond("FetchSourceManga", source: taurus, .success(try fixture("fetch-source-manga-taurus-search")))
    }

    // MARK: Source list cache

    @Test func theConnectionOnlySearchesTheLibrary() async throws {
        defer { cleanUp() }
        try respondSpanishSources()
        let runner = makeRunner()
        #expect(try await runner.getListings().map(\.id) == ["library"])
        let withText = try await runner.getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(withText.entries.map(\.key) == ["156"])
        let search = try await runner.getSearchMangaList(query: nil, page: 1, filters: [])
        let listing = try await runner.getMangaList(listing: SuwayomiServerSources.libraryListing(), page: 1)
        #expect(search.entries.map(\.key) == ["156"])
        #expect(listing.entries.map(\.key) == ["156"])
        #expect(server.count("FetchSourceManga") == 0)
    }

    // MARK: Server sources (each one an Aidoku source of its own, SUWA-12)

    @Test func aServerSourceListsItsPopularAndLatest() async throws {
        defer { cleanUp() }
        server.respond("FetchSourceManga", .success(try fixture("fetch-source-manga-olympus-search")))
        let child = makeChild(olympus)
        #expect(try await child.getListings().map(\.id) == ["popular-\(olympus)", "latest-\(olympus)"])
        #expect(try await makeChild(nexus, supportsLatest: false).getListings().map(\.id) == ["popular-\(nexus)"])
        // (try?: a failure is the assertion below, not an error)
        let page = try? await child.getMangaList(listing: .init(id: "latest-\(olympus)", name: "", kind: .default), page: 2)
        #expect(page?.entries.count == 10)
        #expect(page?.entries.allSatisfy { $0.sourceKey == "\(key).\(olympus)" } == true) // the child's key
        let variables = try #require(server.variables("FetchSourceManga").first)
        #expect(variables["source"] as? String == olympus)
        #expect(variables["type"] as? String == "LATEST")
        #expect(variables["page"] as? Int == 2)
        // another source's list or the library: nothing, not asked
        _ = try? await child.getMangaList(listing: .init(id: "popular-\(emperor)", name: "", kind: .default), page: 1)
        _ = try? await child.getMangaList(listing: SuwayomiServerSources.libraryListing(), page: 1)
        #expect(server.count("FetchSourceManga") == 1)
        #expect(server.count("SearchManga") == 0)
    }

    @Test func aServerSourceSearchesOnlyItself() async throws {
        defer { cleanUp() }
        server.respond("FetchSourceManga", .success(try fixture("fetch-source-manga-taurus-search")))
        let child = makeChild(taurus)
        let page = try? await child.getSearchMangaList(query: "solo", page: 1, filters: [])
        #expect(page?.entries.count == 25)
        #expect(server.variables("FetchSourceManga").map { $0["source"] as? String } == [taurus])
        #expect(server.variables("FetchSourceManga").first?["type"] as? String == "SEARCH")
        #expect(server.timeouts("FetchSourceManga") == [30])
        // without text: its popular list; never the server library
        _ = try? await child.getSearchMangaList(query: nil, page: 1, filters: [])
        #expect(server.variables("FetchSourceManga").last?["type"] as? String == "POPULAR")
        #expect(server.count("SearchManga") == 0)
        // no filters nor settings of its own
        #expect(try await child.getSearchFilters().isEmpty)
        #expect(try await child.getSettings().isEmpty)
        #expect(server.count("GetCategories") == 0)
    }

    @Test func aServerSourceUsesTheConnectionsServerAndLogin() async throws {
        defer {
            cleanUp()
            for suffix in ["login.username", "login.password"] {
                UserDefaults.standard.removeObject(forKey: "\(key).\(suffix)")
            }
        }
        UserDefaults.standard.set("usuario", forKey: "\(key).login.username")
        UserDefaults.standard.set("clave-de-prueba", forKey: "\(key).login.password")
        let requests = SuwayomiRequestLog()
        let child = makeChild(olympus)
        let config = try #require(SuwayomiConnections.shared.child("\(key).\(olympus)"))
        let logged = SuwayomiSourceRunner(
            sourceKey: config.key, name: config.name, server: "", serverSource: config,
            transport: requests.recording(server.transport)
        )
        server.respond("FetchSourceManga", .success(try fixture("fetch-source-manga-olympus-search")))
        _ = try? await logged.getSearchMangaList(query: "solo", page: 1, filters: [])
        _ = child
        let request = try #require(requests.all.first)
        #expect(request.url?.absoluteString == "https://suwayomi.example:4567/api/graphql")
        let expected = "Basic " + Data("usuario:clave-de-prueba".utf8).base64EncodedString()
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        // and the images
        let image = try? await logged.getImageRequest(url: "https://suwayomi.example:4567/api/v1/manga/1/thumbnail", context: nil)
        #expect(image?.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func searchesOfOneServerAreAtMostFourAtATime() async throws {
        defer { cleanUp() }
        server.respond("FetchSourceManga", delay: 0.3, .success(try fixture("fetch-source-manga-taurus-search")))
        let limiter = SuwayomiSearchLimiter()
        let children = (0..<8).map { makeChild("10\($0)", limiter: limiter) }
        await withTaskGroup(of: Void.self) { group in
            for child in children {
                group.addTask {
                    _ = try? await child.getSearchMangaList(query: "solo", page: 1, filters: [])
                }
            }
        }
        #expect(server.count("FetchSourceManga") == 8)
        #expect(server.maxInFlight("FetchSourceManga") <= 4)
        #expect(server.maxInFlight("FetchSourceManga") >= 2) // they do run in parallel
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

    // MARK: SUWA-34: forced search on the scan's website (the user's pull to refresh)

    /// The server's answer for a manga it keeps updated itself: initialized, in its library, 26 chapters stored.
    private func storedInLibrary() throws -> Data {
        Data(String(decoding: try fixture("manga-update-initialized"), as: UTF8.self)
            .replacingOccurrences(of: "\"inLibrary\": false", with: "\"inLibrary\": true").utf8)
    }

    /// The same manga after the server found a new chapter on the website: 27 chapters.
    private func withANewChapter() throws -> Data {
        var json = try #require(JSONSerialization.jsonObject(with: try storedInLibrary()) as? [String: Any])
        var data = try #require(json["data"] as? [String: Any])
        var chapters = try #require(data["chapters"] as? [String: Any])
        var nodes = try #require(chapters["nodes"] as? [[String: Any]])
        var newest = nodes[0]
        newest["id"] = 27
        newest["name"] = "Ch.26 - Capítulo nuevo"
        newest["chapterNumber"] = 26
        newest["sourceOrder"] = 26
        nodes.insert(newest, at: 0)
        chapters["nodes"] = nodes
        data["chapters"] = chapters
        json["data"] = data
        return try JSONSerialization.data(withJSONObject: json)
    }

    private func updateInLibrary(_ runner: SuwayomiSourceRunner) async throws -> AidokuRunner.Manga {
        try await runner.getMangaUpdate(
            manga: .init(sourceKey: key, key: "54", title: "x"),
            needsDetails: true,
            needsChapters: true
        )
    }

    @Test func forcedUpdateSearchesTheOriginAndReturnsTheNewChapters() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try storedInLibrary()), .success(try withANewChapter()))
        server.respond("FetchChapters", .success(try fixture("fetch-chapters")))
        let runner = makeRunner()
        let manga = try await SuwayomiServerSources.$forceOriginFetch.withValue(true) {
            try await updateInLibrary(runner)
        }
        #expect(server.count("FetchChapters") == 1)
        #expect(server.count("FetchManga") == 0)
        #expect(server.count("GetMangaUpdate") == 2)
        #expect(manga.chapters?.count == 27)
        #expect(manga.chapters?.first?.title == "Ch.26 - Capítulo nuevo")
    }

    @Test func unforcedUpdateDoesNotSearchTheOrigin() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try storedInLibrary()))
        let runner = makeRunner()
        let manga = try await updateInLibrary(runner)
        #expect(server.count("FetchChapters") == 0)
        #expect(server.count("GetMangaUpdate") == 1)
        #expect(manga.chapters?.count == 26)
    }

    @Test func forcedUpdateWithAFailingSearchReturnsWhatIsStored() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try storedInLibrary()))
        server.respond("FetchChapters", .failure(URLError(.timedOut)))
        let runner = makeRunner()
        let manga = try await SuwayomiServerSources.$forceOriginFetch.withValue(true) {
            try await updateInLibrary(runner)
        }
        #expect(server.count("FetchChapters") == 1)
        #expect(server.count("GetMangaUpdate") == 1) // nothing was fetched: no second query
        #expect(manga.chapters?.count == 26)
    }

    @Test func forcedUpdateOnlyAsksForChaptersWhenTheyWereAsked() async throws {
        defer { cleanUp() }
        server.respond("GetMangaUpdate", .success(try fixture("manga-update-state-only")))
        let runner = makeRunner()
        _ = try await SuwayomiServerSources.$forceOriginFetch.withValue(true) {
            try await runner.getMangaUpdate(
                manga: .init(sourceKey: key, key: "54", title: "x"),
                needsDetails: false,
                needsChapters: false
            )
        }
        #expect(server.count("FetchChapters") == 0)
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
        await DataRepositories.shared.tracks.add(TrackItem(id: "\(key)|77", trackerId: tracker.id, mangaId: mangaId, title: nil, chapterOffset: 0))
        await tracker.logout()
        let left = await DataRepositories.shared.tracks.contains(trackerId: tracker.id, manga: mangaId)
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

    // MARK: Migration

    @Test func migrationPlanFollowsJoTasRule() {
        let old = MangaIdentifier(sourceKey: key, mangaKey: "753")
        let new = MangaIdentifier(sourceKey: key, mangaKey: "897")
        let other = MangaIdentifier(sourceKey: "otra", mangaKey: "1")
        typealias Plan = SuwayomiMigrationPlan
        // migrate (and «migrate and keep history»): only the new one stays, tracked by its own id
        #expect(Plan.make(old: old, new: new, oldIsServer: true, newIsServer: true, oldLeavesLibrary: true)
            == Plan(newTrackId: "\(key)|897", registerNew: true, removeOld: true))
        // copy: the old one stays on the server too
        #expect(Plan.make(old: old, new: new, oldIsServer: true, newIsServer: true, oldLeavesLibrary: false)
            == Plan(newTrackId: "\(key)|897", registerNew: true, removeOld: false))
        // to another kind of source: out of the server library, nothing to track
        #expect(Plan.make(old: old, new: other, oldIsServer: true, newIsServer: false, oldLeavesLibrary: true)
            == Plan(newTrackId: nil, registerNew: false, removeOld: true))
        #expect(Plan.make(old: old, new: other, oldIsServer: true, newIsServer: false, oldLeavesLibrary: false) == .none)
        // from another kind of source
        #expect(Plan.make(old: other, new: new, oldIsServer: false, newIsServer: true, oldLeavesLibrary: true)
            == Plan(newTrackId: "\(key)|897", registerNew: true, removeOld: false))
        // the same manga (e.g. refreshed in place): nothing
        #expect(Plan.make(old: old, new: old, oldIsServer: true, newIsServer: true, oldLeavesLibrary: true) == .none)
    }

    private func respondMigration() {
        server.respond("GetInLibrary", .success(notInLibrary))
        server.respond("AddToServerLibrary", .success(Data(#"{"data":{"updateManga":{"manga":{"id":897,"inLibrary":true}}}}"#.utf8)))
        server.respond("GetTrackState", .success(Data(#"{"data":{"manga":{"chapters":{"totalCount":198},"latestReadChapter":null,"highestNumberedChapter":{"chapterNumber":198}}}}"#.utf8)))
        server.respond("GetChaptersForTrackUpdate", .success(Data(#"{"data":{"chapters":{"nodes":[{"id":6764,"chapterNumber":1}]}}}"#.utf8)))
        server.respond("MarkChaptersRead", .success(Data(#"{"data":{"updateChapters":{"chapters":[]}}}"#.utf8)))
        server.respond("RemoveFromServerLibrary", .success(Data(#"{"data":{"updateManga":{"manga":{"id":753,"inLibrary":false}}}}"#.utf8)))
    }

    @Test func migratingMovesTheServerLibraryToTheNewManga() async {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        respondMigration()
        let tracker = makeTracker()
        let old = MangaIdentifier(sourceKey: key, mangaKey: "753")
        let new = MangaIdentifier(sourceKey: key, mangaKey: "897")
        let plan = SuwayomiMigrationPlan.make(old: old, new: new, oldIsServer: true, newIsServer: true, oldLeavesLibrary: true)
        await tracker.applyMigration(plan, old: old, highestChapterRead: 1)
        #expect(server.variables("AddToServerLibrary").map { $0["id"] as? Int } == [897])
        #expect(server.variables("GetChaptersForTrackUpdate").first?["mangaId"] as? Int == 897)
        #expect(server.count("MarkChaptersRead") == 1)
        #expect(server.variables("RemoveFromServerLibrary").map { $0["id"] as? Int } == [753])
    }

    @Test func copyingLeavesTheOldMangaOnTheServer() async {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        respondMigration()
        let tracker = makeTracker()
        let old = MangaIdentifier(sourceKey: key, mangaKey: "753")
        let new = MangaIdentifier(sourceKey: key, mangaKey: "897")
        let plan = SuwayomiMigrationPlan.make(old: old, new: new, oldIsServer: true, newIsServer: true, oldLeavesLibrary: false)
        await tracker.applyMigration(plan, old: old, highestChapterRead: nil)
        #expect(server.variables("AddToServerLibrary").map { $0["id"] as? Int } == [897])
        #expect(server.count("RemoveFromServerLibrary") == 0)
        #expect(server.count("MarkChaptersRead") == 0) // nothing read: no marks
    }

    @Test func serverFailuresDontStopTheMigration() async {
        defer { UserDefaults.standard.removeObject(forKey: "\(key).server") }
        respondMigration()
        server.respond("AddToServerLibrary", .failure(URLError(.timedOut)))
        let tracker = makeTracker()
        let old = MangaIdentifier(sourceKey: key, mangaKey: "753")
        let plan = SuwayomiMigrationPlan.make(
            old: old, new: .init(sourceKey: "otra", mangaKey: "1"), oldIsServer: true, newIsServer: false, oldLeavesLibrary: true
        )
        await tracker.applyMigration(plan, old: old, highestChapterRead: 3) // doesn't throw
        #expect(server.count("AddToServerLibrary") == 0)
        #expect(server.variables("RemoveFromServerLibrary").map { $0["id"] as? Int } == [753])
        // the new one failing to be added: logged, the old one still goes
        let both = SuwayomiMigrationPlan.make(
            old: old, new: .init(sourceKey: key, mangaKey: "897"), oldIsServer: true, newIsServer: true, oldLeavesLibrary: true
        )
        await tracker.applyMigration(both, old: old, highestChapterRead: 1)
        #expect(server.count("RemoveFromServerLibrary") == 2)
    }
}
