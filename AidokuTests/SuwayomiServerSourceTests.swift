//
//  SuwayomiServerSourceTests.swift
//  AidokuTests
//
//  SUWA-12: each source installed on the Suwayomi server is an Aidoku source of its own; the parent
//  (the Suwayomi source of the setup) is only the connection.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct SuwayomiServerSourceTests {
    let parent = "suwayomi.conexiontest"
    let olympus = "1596411039134168890"

    private func child(_ id: String = "1596411039134168890", available: Bool = true, nsfw: Bool = false, latest: Bool = true) -> SuwayomiServerSourceConfig {
        .init(
            key: SuwayomiServerSourceConfig.key(parentKey: parent, serverSourceId: id),
            parentKey: parent,
            serverSourceId: id,
            name: "Olympus Scanlation",
            lang: "es",
            iconUrl: "/api/v1/extension/icon/eu.kanade.tachiyomi.extension.es.olympusscanlation",
            isNsfw: nsfw,
            supportsLatest: latest,
            available: available
        )
    }

    private func cleanUp() {
        SuwayomiConnections.shared.unregister(parent)
        for child in SuwayomiConnections.shared.children(of: parent) {
            SuwayomiConnections.shared.unregister(child.key)
        }
        for suffix in ["server", "login.username", "login.password", "disableTracking"] {
            UserDefaults.standard.removeObject(forKey: "\(parent).\(suffix)")
        }
    }

    // MARK: Config (D1, D2)

    @Test func theKeyIsTheParentAndTheServerSourceId() {
        #expect(SuwayomiServerSourceConfig.key(parentKey: "suwayomi.suwa", serverSourceId: olympus) == "suwayomi.suwa.\(olympus)")
        let server = SuwayomiServerSource(
            id: olympus, name: "Olympus Scanlation", lang: "es", displayName: "Olympus Scanlation (ES)",
            isNsfw: false, supportsLatest: true, iconUrl: "/api/v1/extension/icon/x"
        )
        let config = SuwayomiServerSourceConfig(parentKey: "suwayomi.suwa", server: server)
        #expect(config.key == "suwayomi.suwa.\(olympus)")
        #expect(config.name == "Olympus Scanlation") // the language is shown apart
        #expect(config.languages == ["es"])
        #expect(config.contentRating == .safe)
        #expect(config.available)
        var all = config
        all.lang = "all"
        all.isNsfw = true
        #expect(all.languages == ["multi"])
        #expect(all.contentRating == .containsNsfw)
    }

    @Test func serverSourceConfigsGoAndComeBackAsTheyWere() throws {
        for (available, nsfw, latest) in [(true, false, true), (false, true, false), (true, true, true), (false, false, false)] {
            let config = child(available: available, nsfw: nsfw, latest: latest)
            let data = CustomSourceConfig.suwayomiServerSource(config).encode()
            #expect(data.first == 5)
            guard case let .suwayomiServerSource(decoded) = try CustomSourceConfig(from: data) else {
                Issue.record("not a server source")
                continue
            }
            #expect(decoded == config)
        }
        // the old ones still decode, an unknown type still fails
        let old = CustomSourceConfig.suwayomi(.init(key: "suwayomi.suwa", name: "Suwa", server: "https://x"))
        guard case let .suwayomi(decodedOld) = try CustomSourceConfig(from: old.encode()) else {
            Issue.record("not suwayomi")
            return
        }
        #expect(decodedOld.key == "suwayomi.suwa")
        #expect(throws: DecodingError.self) { try CustomSourceConfig(from: Data([6, 0])) }
        var truncated = CustomSourceConfig.suwayomiServerSource(child()).encode()
        truncated.removeLast() // no flags
        #expect(throws: DecodingError.self) { try CustomSourceConfig(from: truncated) }
    }

    @Test func aServerSourceIsBuiltWithoutTheServer() {
        defer { cleanUp() }
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(parent).server")
        let source = CustomSourceConfig.suwayomiServerSource(child(nsfw: true)).toSource()
        #expect(source.key == "\(parent).\(olympus)")
        #expect(source.name == "Olympus Scanlation")
        #expect(source.languages == ["es"])
        #expect(source.contentRating == .containsNsfw)
        #expect(source.hasListings && !source.features.dynamicListings)
        #expect(source.urls.first?.absoluteString == "https://suwayomi.example:4567")
    }

    // MARK: Connection (D3, T5)

    @Test func theConnectionOfAServerSourceIsItsParent() {
        defer { cleanUp() }
        SuwayomiConnections.shared.register(connection: parent)
        SuwayomiConnections.shared.register(child: child())
        #expect(SuwayomiConnections.shared.connectionKey(for: "\(parent).\(olympus)") == parent)
        #expect(SuwayomiConnections.shared.connectionKey(for: parent) == parent)
        #expect(SuwayomiConnections.shared.connectionKey(for: "suwayomi.otra") == "suwayomi.otra")
        // from the saved config, not the key: a key that only looks like a child is itself
        #expect(SuwayomiConnections.shared.connectionKey(for: "\(parent).999") == "\(parent).999")
        // the helper reads the parent's server
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(parent).server")
        let helper = SuwayomiHelper(sourceKey: "\(parent).\(olympus)")
        #expect(helper.sourceKey == parent)
        #expect((try? helper.getConfiguredServer())?.absoluteString == "https://suwayomi.example:4567/")
    }

    @Test func oldAndNewTrackIdsGoToTheConnection() async throws {
        defer { cleanUp() }
        SuwayomiConnections.shared.register(connection: parent)
        SuwayomiConnections.shared.register(child: child())
        UserDefaults.standard.set("https://suwayomi.example:4567", forKey: "\(parent).server")
        UserDefaults.standard.set("usuario-prueba", forKey: "\(parent).login.username")
        UserDefaults.standard.set("clave-de-prueba", forKey: "\(parent).login.password")
        let server = SuwayomiFakeServer()
        server.respond("UpdateChapterProgress", .success(Data(#"{"data":{"updateChapter":{"chapter":{"id":11}}}}"#.utf8)))
        server.respond("GetTrackState", .success(Data(#"{"data":{"manga":{"chapters":{"totalCount":3},"latestReadChapter":null,"highestNumberedChapter":{"chapterNumber":3}}}}"#.utf8)))
        let log = SuwayomiRequestLog()
        let tracker = SuwayomiTracker(api: SuwayomiApi(transport: log.recording(server.transport)))
        let chapter = ChapterIdentifier(sourceKey: "\(parent).\(olympus)", mangaKey: "56", chapterKey: "11")
        // a track id from before the conversion (`<parent>|<id>`) and a new one (`<child>|<id>`)
        for trackId in ["\(parent)|56", "\(parent).\(olympus)|56"] {
            try? await tracker.setProgress(trackId: trackId, chapterId: chapter, progress: .init(completed: false, page: 3))
            _ = try? await tracker.getState(trackId: trackId)
        }
        let expected = "Basic " + Data("jota:clave-de-prueba".utf8).base64EncodedString()
        let requests = log.all
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.url?.absoluteString == "https://suwayomi.example:4567/api/graphql" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == expected })
        // the search of a child's manga gives a child track id
        let found = try? await tracker.search(for: .init(sourceKey: "\(parent).\(olympus)", key: "56", title: "x"), includeNsfw: true)
        #expect(found?.first?.id == "\(parent).\(olympus)|56")
    }

    @Test func aServerSourceFollowsTheConnectionsTrackingSwitch() {
        defer { cleanUp() }
        SuwayomiConnections.shared.register(connection: parent)
        SuwayomiConnections.shared.register(child: child())
        let tracker = SuwayomiTracker()
        let manga = MangaIdentifier(sourceKey: "\(parent).\(olympus)", mangaKey: "56")
        #expect(tracker.canRegister(mangaId: manga))
        UserDefaults.standard.set(true, forKey: "\(parent).disableTracking")
        #expect(!tracker.canRegister(mangaId: manga))
        #expect(!tracker.canRegister(mangaId: .init(sourceKey: parent, mangaKey: "56")))
    }

    // MARK: Lists (D5)

    @Test func theConnectionAndAMissingServerSourceAreNotListed() {
        defer { cleanUp() }
        SuwayomiConnections.shared.register(connection: parent)
        SuwayomiConnections.shared.register(child: child())
        SuwayomiConnections.shared.register(child: child("777", available: false))
        #expect(!SuwayomiConnections.shared.isListed(parent))
        #expect(SuwayomiConnections.shared.isListed("\(parent).\(olympus)"))
        #expect(!SuwayomiConnections.shared.isListed("\(parent).777"))
        #expect(SuwayomiConnections.shared.isListed("multi.mangadex"))
    }

    @Test func emperorAndNexusStayWithTheDefaultContentRatings() {
        // JoTa's devices keep the default: «may contain NSFW» sources are shown
        let defaults = AppSettings.browse.contentRatings.defaultValue
        #expect(defaults.contains(child(nsfw: true).contentRating))
    }

    @Test func removingASourcesSettingsDoesntTouchAnotherThatStartsTheSame() {
        let defaults = UserDefaults.standard
        let keys = ["suwayomi.borrar.server", "suwayomi.borrar", "suwayomi.borrar-1.server", "suwayomi.borrar.123.filters", "suwayomi.borrarx"]
        for key in keys { defaults.set("x", forKey: key) }
        defer { for key in keys { defaults.removeObject(forKey: key) } }
        SourceManager.shared.removeSettings(from: "suwayomi.borrar")
        #expect(defaults.string(forKey: "suwayomi.borrar.server") == nil)
        #expect(defaults.string(forKey: "suwayomi.borrar") == nil)
        #expect(defaults.string(forKey: "suwayomi.borrar.123.filters") == nil) // its server sources go with it
        #expect(defaults.string(forKey: "suwayomi.borrar-1.server") == "x")
        #expect(defaults.string(forKey: "suwayomi.borrarx") == "x")
    }
}
