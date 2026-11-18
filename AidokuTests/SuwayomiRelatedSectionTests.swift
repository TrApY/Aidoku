//
//  SuwayomiRelatedSectionTests.swift
//  AidokuTests
//
//  SUWA-18 A2: the «Relacionados» row of the manga page: only for a library manga of a Suwayomi server
//  source whose suwa.related.v1 has elements; otherwise nothing is asked and nothing is drawn.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct SuwayomiRelatedSectionTests {
    let key = "suwayomi.recs-a2"
    let server = SuwayomiFakeServer()

    private var childKey: String { SuwayomiServerSourceConfig.key(parentKey: key, serverSourceId: RecsFixture.olympus) }

    private func child(_ sourceKey: String) -> SuwayomiServerSourceConfig? {
        guard sourceKey == childKey else { return nil }
        return .init(
            key: childKey, parentKey: key, serverSourceId: RecsFixture.olympus, name: "Olympus", lang: "es",
            iconUrl: "", isNsfw: false, supportsLatest: true, available: true
        )
    }

    private func load(
        sourceKey: String? = nil,
        mangaKey: String = "156",
        inLibrary: Bool = true,
        force: Bool = false,
        cache: SuwayomiRecsCache,
        transport: SuwayomiHelper.Transport? = nil
    ) async -> [SuwayomiRecs.Entry] {
        RecsFixture.setServer(key)
        return await SuwayomiRecs.loadRelated(
            sourceKey: sourceKey ?? childKey,
            mangaKey: mangaKey,
            inLibrary: inLibrary,
            force: force,
            cache: cache,
            transport: transport ?? server.transport,
            child: child
        )
    }

    private func respondWithRelated() {
        server.respond("SuwaRecsRelated", .success(RecsFixture.relatedAnswer(RecsFixture.list([
            (1475, RecsFixture.crab, "Cazador con sistema"),
            (156, RecsFixture.olympus, "el propio manga"),
            (1470, RecsFixture.crab, "Cazador legendario")
        ]))))
        server.respond("SuwaRecsMangas", .success(RecsFixture.mangasAnswer([
            (1470, "Cazador legendario", RecsFixture.crab, false),
            (1475, "Cazador automático", RecsFixture.crab, false)
        ])))
    }

    @Test func onlyALibraryMangaOfAServerSourceIsATarget() {
        let target = SuwayomiRecs.relatedTarget(sourceKey: childKey, mangaKey: "156", inLibrary: true, child: child)
        #expect(target.map { "\($0.parentKey)|\($0.mangaId)" } == "\(key)|156")
        #expect(SuwayomiRecs.relatedTarget(sourceKey: childKey, mangaKey: "156", inLibrary: false, child: child) == nil)
        #expect(SuwayomiRecs.relatedTarget(sourceKey: "multi.mangadex", mangaKey: "156", inLibrary: true, child: child) == nil)
        #expect(SuwayomiRecs.relatedTarget(sourceKey: childKey, mangaKey: "abc", inLibrary: true, child: child) == nil)
    }

    @Test func aMangaOutsideTheLibraryAsksNothingAndShowsNothing() async {
        defer { RecsFixture.clearServer(key) }
        respondWithRelated()
        let entries = await load(inLibrary: false, cache: SuwayomiRecsCache(directory: nil))
        #expect(entries.isEmpty)
        #expect(!SuwayomiRecs.showsRelated(entries))
        #expect(server.count("SuwaRecsRelated") == 0)
    }

    @Test func aMangaOfAnotherSourceAsksNothing() async {
        defer { RecsFixture.clearServer(key) }
        respondWithRelated()
        let entries = await load(sourceKey: "multi.mangadex", cache: SuwayomiRecsCache(directory: nil))
        #expect(entries.isEmpty)
        #expect(server.count("SuwaRecsRelated") == 0)
    }

    @Test func aLibraryMangaShowsItsRelatedWithoutItself() async {
        defer { RecsFixture.clearServer(key) }
        respondWithRelated()
        let entries = await load(cache: SuwayomiRecsCache(directory: nil))
        #expect(entries.map(\.mangaId) == [1475, 1470])
        #expect(entries.map(\.title) == ["Cazador automático", "Cazador legendario"])
        #expect(entries.map(\.reason) == ["Cazador con sistema", "Cazador legendario"])
        #expect(entries.allSatisfy { $0.sourceKey == "\(key).\(RecsFixture.crab)" })
        #expect(SuwayomiRecs.showsRelated(entries))
        #expect(server.variables("SuwaRecsRelated").first?["mangaId"] as? Int == 156)
        #expect(server.variables("SuwaRecsMangas").first?["ids"] as? [Int] == [1475, 1470])
    }

    @Test func withoutTheMetaThereIsNoSection() async {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsRelated", .success(RecsFixture.relatedAnswer(nil)))
        let entries = await load(cache: SuwayomiRecsCache(directory: nil))
        #expect(entries.isEmpty)
        #expect(!SuwayomiRecs.showsRelated(entries))
        #expect(server.count("SuwaRecsRelated") == 1)
        #expect(server.count("SuwaRecsMangas") == 0)
    }

    @Test func anEmptyMetaHasNoSection() async {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsRelated", .success(RecsFixture.relatedAnswer(#"{"v":1,"at":"a","items":[]}"#)))
        let entries = await load(cache: SuwayomiRecsCache(directory: nil))
        #expect(entries.isEmpty)
        #expect(server.count("SuwaRecsMangas") == 0)
    }

    @Test func aMangaTheServerDoesntHaveHasNoSection() async {
        defer { RecsFixture.clearServer(key) }
        server.respond("SuwaRecsRelated", .success(RecsFixture.graphQLError("manga")))
        let entries = await load(cache: SuwayomiRecsCache(directory: nil))
        #expect(entries.isEmpty)
        #expect(server.count("SuwaRecsRelated") == 1)
    }

    @Test func theSessionReadsOnceUntilPullToRefresh() async {
        defer { RecsFixture.clearServer(key) }
        respondWithRelated()
        let cache = SuwayomiRecsCache(directory: nil)
        let first = await load(cache: cache)
        let second = await load(cache: cache)
        #expect(second == first)
        #expect(server.count("SuwaRecsRelated") == 1)
        _ = await load(force: true, cache: cache)
        #expect(server.count("SuwaRecsRelated") == 2)
    }

    @Test func aFailedReadShowsTheCopyOfAnEarlierSession() async throws {
        defer { RecsFixture.clearServer(key) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recs-a2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        respondWithRelated()
        let first = await load(cache: SuwayomiRecsCache(directory: directory))
        #expect(first.count == 2)

        // another session, server unreachable
        let offline: SuwayomiHelper.Transport = { _ in throw URLError(.notConnectedToInternet) }
        let later = await load(cache: SuwayomiRecsCache(directory: directory), transport: offline)
        #expect(later == first)
        let nothingStored = await load(cache: SuwayomiRecsCache(directory: nil), transport: offline)
        #expect(nothingStored.isEmpty)
    }
}
