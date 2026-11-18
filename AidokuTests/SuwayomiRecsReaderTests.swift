//
//  SuwayomiRecsReaderTests.swift
//  AidokuTests
//
//  SUWA-18 A1: reading the recommendation metas of the suwa-recs service (contract suwa.recs.v1,
//  suwa.related.v1, suwa.recs.estado.v1) against a fake GraphQL transport. No network.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

// MARK: Shared by the SUWA-18 tests (A1, A2, A3)

enum RecsFixture {
    static let server = "https://suwayomi.example:4567"
    static let crab = "6167683270485370369"
    static let insanos = "4982291187322723927"
    static let olympus = "1596411039134168890"

    /// A meta value as the service writes it (D3), with an extra field to be ignored.
    static func list(at: String = "2026-11-18T01:11:32+01:00", _ items: [(Int, String, String)]) -> String {
        let body = items.map { m, s, r in
            #"{"m":\#(m),"s":"\#(s)","p":0.39,"r":"\#(r)","extra":true}"#
        }.joined(separator: ",")
        return #"{"v":1,"at":"\#(at)","items":[\#(body)],"otro":"campo"}"#
    }

    static func status(ok: Bool, at: String = "2026-11-19T04:31:00+01:00") -> String {
        #"{"v":1,"at":"\#(at)","ok":\#(ok),"tipo":"completa","msg":"Todo en orden","creditos":0.98,"n_para_ti":20,"n_relacionados":8}"#
    }

    /// GraphQL string literal of a meta value.
    static func quoted(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }

    static func forYouAnswer(recs: String?, estado: String?) -> Data {
        func nodes(_ key: String, _ value: String?) -> String {
            value.map { #"{"nodes":[{"key":"\#(key)","value":\#(quoted($0))}]}"# } ?? #"{"nodes":[]}"#
        }
        return Data(#"{"data":{"recs":\#(nodes(SuwayomiRecs.forYouKey, recs)),"estado":\#(nodes(SuwayomiRecs.statusKey, estado))}}"#.utf8)
    }

    static func relatedAnswer(_ value: String?, otherKeys: Bool = true) -> Data {
        var meta: [String] = otherKeys ? [#"{"key":"flare.app","value":"1"}"#] : []
        if let value {
            meta.append(#"{"key":"\#(SuwayomiRecs.relatedKey)","value":\#(quoted(value))}"#)
        }
        return Data(#"{"data":{"manga":{"meta":[\#(meta.joined(separator: ","))]}}}"#.utf8)
    }

    /// The server's error for a field that doesn't exist (meta(key:) of a missing key, manga(id:) of a
    /// missing manga).
    static func graphQLError(_ path: String) -> Data {
        Data(#"{"errors":[{"message":"The field at path '/\#(path)' was declared as a non null type, but the code involved in retrieving data has wrongly returned a null value.","locations":[],"path":["\#(path)"]}],"data":null}"#.utf8)
    }

    /// `mangas(filter:{id:{in:…}})`: the server answers in id order and leaves out ids it doesn't have.
    static func mangasAnswer(_ nodes: [(id: Int, title: String, source: String, inLibrary: Bool)]) -> Data {
        let body = nodes.sorted { $0.id < $1.id }.map { node in
            #"{"id":\#(node.id),"title":"\#(node.title)","thumbnailUrl":"/api/v1/manga/\#(node.id)/thumbnail","inLibrary":\#(node.inLibrary),"sourceId":"\#(node.source)","source":{"displayName":"Fuente \#(node.source.prefix(4)) (ES)"}}"#
        }.joined(separator: ",")
        return Data(#"{"data":{"mangas":{"nodes":[\#(body)]}}}"#.utf8)
    }

    static func setServer(_ key: String) {
        UserDefaults.standard.set(server, forKey: "\(key).server")
    }

    static func clearServer(_ key: String) {
        UserDefaults.standard.removeObject(forKey: "\(key).server")
    }

    /// The GraphQL documents sent (to check they are all queries).
    static func documents(_ log: SuwayomiRequestLog) -> [String] {
        log.all.compactMap { request in
            request.httpBody
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["query"] as? String }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: A1

@Suite(.serialized) struct SuwayomiRecsReaderTests {
    let key = "suwayomi.recs-a1"
    let server = SuwayomiFakeServer()

    private func reader(deadline: TimeInterval = SuwayomiRecs.timeout, log: SuwayomiRequestLog? = nil) -> SuwayomiRecsReader {
        RecsFixture.setServer(key)
        let transport = log.map { $0.recording(server.transport) } ?? server.transport
        return SuwayomiRecsReader(parentKey: key, transport: transport, deadline: deadline)
    }

    // MARK: Decoding

    @Test func aValidValueIsDecodedInItsOrderIgnoringExtraFields() {
        let list = SuwayomiRecs.decode(RecsFixture.list([
            (1645, RecsFixture.crab, "Paladín oculto"),
            (291, RecsFixture.insanos, "Jugador con sistema")
        ]))
        #expect(list.at == "2026-11-18T01:11:32+01:00")
        #expect(list.items.map(\.mangaId) == [1645, 291])
        #expect(list.items.map(\.serverSourceId) == [RecsFixture.crab, RecsFixture.insanos])
        #expect(list.items.map(\.reason) == ["Paladín oculto", "Jugador con sistema"])
        #expect(list.items.first?.score == 0.39)
    }

    @Test func aVersionOtherThanOneIsEmpty() {
        #expect(SuwayomiRecs.decode(#"{"v":2,"at":"x","items":[{"m":1,"s":"10","r":"a"}]}"#) == .empty)
        #expect(SuwayomiRecs.decode(#"{"at":"x","items":[{"m":1,"s":"10","r":"a"}]}"#) == .empty)
        #expect(SuwayomiRecs.decode(#"{"v":"1","items":[{"m":1,"s":"10","r":"a"}]}"#) == .empty)
    }

    @Test func brokenJsonIsEmpty() {
        #expect(SuwayomiRecs.decode(#"{"v":1,"items":[{"m":1,"s":"10""#) == .empty)
        #expect(SuwayomiRecs.decode("") == .empty)
        #expect(SuwayomiRecs.decode(nil) == .empty)
        #expect(SuwayomiRecs.decode("[1,2]") == .empty)
    }

    @Test func noItemsIsEmpty() {
        #expect(SuwayomiRecs.decode(#"{"v":1,"at":"2026-11-18T01:11:32+01:00"}"#).items.isEmpty)
        #expect(SuwayomiRecs.decode(#"{"v":1,"items":{"m":1,"s":"10"}}"#).items.isEmpty)
        #expect(SuwayomiRecs.decode(#"{"v":1,"items":[]}"#).items.isEmpty)
    }

    @Test func incompleteElementsAreSkippedAndTheRestKept() {
        let value = #"""
            {"v":1,"at":"a","items":[
              {"m":1,"s":"10"},
              {"s":"10","r":"sin manga"},
              {"m":2,"r":"sin fuente"},
              {"m":"x","s":"10"},
              5,
              {"m":3,"s":"abc"},
              {"m":1,"s":"20","r":"repetido"},
              {"m":4,"s":"20","r":"bien","p":"no es un número"}
            ]}
            """#
        let list = SuwayomiRecs.decode(value)
        #expect(list.items.map(\.mangaId) == [1, 4])
        #expect(list.items.map(\.serverSourceId) == ["10", "20"])
        #expect(list.items.map(\.reason) == ["", "bien"])
        #expect(list.items.last?.score == nil)
    }

    @Test func theStatusIsDecodedAndInvalidOnesAreNil() {
        #expect(SuwayomiRecs.decodeStatus(RecsFixture.status(ok: false)) == .init(
            at: "2026-11-19T04:31:00+01:00", ok: false, message: "Todo en orden"
        ))
        #expect(SuwayomiRecs.decodeStatus(RecsFixture.status(ok: true))?.ok == true)
        #expect(SuwayomiRecs.decodeStatus(#"{"v":2,"ok":true}"#) == nil)
        #expect(SuwayomiRecs.decodeStatus(#"{"v":1,"ok":tru"#) == nil)
        #expect(SuwayomiRecs.decodeStatus(nil) == nil)
    }

    @Test func theChildSourceKeyIsTheConnectionDotTheServerSourceId() {
        let child = SuwayomiRecs.childKey(parentKey: "suwayomi", serverSourceId: RecsFixture.crab)
        #expect(child == "suwayomi.\(RecsFixture.crab)")
        #expect(child == SuwayomiServerSourceConfig.key(parentKey: "suwayomi", serverSourceId: RecsFixture.crab))
    }

    @Test func entriesSkipMissingIdsAndLibraryMangaInTheMetaOrder() throws {
        let items = SuwayomiRecs.decode(RecsFixture.list([
            (1645, RecsFixture.crab, "uno"),
            (99_999, RecsFixture.crab, "ya no existe"),
            (777, RecsFixture.olympus, "en la biblioteca"),
            (291, RecsFixture.insanos, "dos")
        ])).items
        let nodes = try JSONDecoder().decode(SuwayomiRecs.MangasResponse.self, from: RecsFixture.mangasAnswer([
            (291, "Extiendo mi vida", RecsFixture.insanos, false),
            (777, "Ya la tengo", RecsFixture.olympus, true),
            (1645, "Paladín de rango SSS", RecsFixture.crab, false)
        ])).data?.mangas?.nodes ?? []
        let entries = SuwayomiRecs.entries(
            items: items, nodes: nodes, parentKey: key,
            baseUrl: try #require(URL(string: "\(RecsFixture.server)/")),
            sourceName: { $0.hasSuffix(RecsFixture.crab) ? "Manga Crab" : nil }
        )
        #expect(entries.map(\.mangaId) == [1645, 291])
        #expect(entries.map(\.title) == ["Paladín de rango SSS", "Extiendo mi vida"])
        #expect(entries.map(\.sourceKey) == ["\(key).\(RecsFixture.crab)", "\(key).\(RecsFixture.insanos)"])
        #expect(entries.map(\.sourceName) == ["Manga Crab", "Fuente 4982 (ES)"])
        #expect(entries.first?.cover == "\(RecsFixture.server)/api/v1/manga/1645/thumbnail")
        #expect(entries.first?.manga.key == "1645")
        #expect(entries.first?.manga.sourceKey == "\(key).\(RecsFixture.crab)")
    }

    // MARK: Flow against the server

    @Test func forYouReadsTheMetaThenTitlesAndCoversInOneQueryEach() async throws {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsForYou", .success(RecsFixture.forYouAnswer(
            recs: RecsFixture.list([(1645, RecsFixture.crab, "uno"), (99_999, RecsFixture.crab, "x"), (291, RecsFixture.insanos, "dos")]),
            estado: RecsFixture.status(ok: true)
        )))
        server.respond("SuwaRecsMangas", .success(RecsFixture.mangasAnswer([
            (1645, "Paladín", RecsFixture.crab, false), (291, "Extiendo", RecsFixture.insanos, false)
        ])))
        let log = SuwayomiRequestLog()
        let result = try await reader(log: log).forYou()
        #expect(result.entries.map(\.mangaId) == [1645, 291])
        #expect(result.at == "2026-11-18T01:11:32+01:00")
        #expect(result.status?.ok == true)
        #expect(server.count("SuwaRecsForYou") == 1)
        #expect(server.count("SuwaRecsMangas") == 1)
        let ids = server.variables("SuwaRecsMangas").first?["ids"] as? [Int]
        #expect(ids == [1645, 99_999, 291])
        // read only: no mutation is ever sent
        let documents = RecsFixture.documents(log)
        #expect(documents.count == 2)
        #expect(documents.allSatisfy { $0.hasPrefix("query ") })
    }

    @Test func aMissingKeyGraphQLErrorIsNoDataNotAnError() async throws {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsForYou", .success(RecsFixture.graphQLError("meta")))
        let result = try await reader().forYou()
        #expect(result.entries.isEmpty)
        #expect(result.at == nil)
        #expect(server.count("SuwaRecsMangas") == 0)
    }

    @Test func noMetasIsEmptyWithoutAskingForMangas() async throws {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsForYou", .success(RecsFixture.forYouAnswer(recs: nil, estado: nil)))
        let result = try await reader().forYou()
        #expect(result.entries.isEmpty)
        #expect(result.status == nil)
        #expect(server.count("SuwaRecsMangas") == 0)
    }

    @Test func aFailedLastRunKeepsTheListAndItsDate() async throws {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsForYou", .success(RecsFixture.forYouAnswer(
            recs: RecsFixture.list([(1645, RecsFixture.crab, "uno")]),
            estado: RecsFixture.status(ok: false)
        )))
        server.respond("SuwaRecsMangas", .success(RecsFixture.mangasAnswer([(1645, "Paladín", RecsFixture.crab, false)])))
        let result = try await reader().forYou()
        #expect(result.entries.map(\.mangaId) == [1645])
        #expect(result.at == "2026-11-18T01:11:32+01:00")
        #expect(result.status?.ok == false)
    }

    @Test func aNetworkFailureThrowsInsteadOfLookingEmpty() async {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsForYou", .failure(URLError(.notConnectedToInternet)))
        await #expect(throws: (any Error).self) {
            _ = try await reader().forYou()
        }
    }

    @Test func aSlowServerStopsAtTheDeadline() async {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsForYou", delay: 8, .success(RecsFixture.forYouAnswer(recs: nil, estado: nil)))
        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await reader(deadline: 0.5).forYou()
        }
        #expect(Date().timeIntervalSince(start) < 4)
    }
}
