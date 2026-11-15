//
//  ExploreTests.swift
//  AidokuTests
//
//  SUWA-12 encargo B: Explorar as Tachimanga (Fuentes by language with «Usado recientemente», the
//  shared language setting, the server's Extensiones and Migrar per server source).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

private func info(_ key: String, _ name: String, _ languages: [String]) -> Aidoku.SourceInfo {
    Aidoku.SourceInfo(sourceId: key, name: name, languages: languages, version: 1, contentRating: .safe)
}

// MARK: B1

struct BrowseSourceGroupingTests {
    private let sources = [
        info("suwa.olympus", "Olympus Scanlation", ["es"]),
        info("suwa.emperor", "Emperor Scan", ["es"]),
        info("aidoku.en", "English Source", ["en"]),
        info("aidoku.multi", "Varias", ["en", "es"]),
        info("aidoku.ja", "Japanese", ["ja"]),
        info("aidoku.pt", "Brasil", ["pt-BR"])
    ]

    @Test func sourcesAreGroupedByActiveLanguageWithTheDevicesFirstAndMultiLast() {
        let groups = BrowseSourceGroups.make(
            installed: sources, pinnedKeys: [], recents: [:], active: ["es", "en", "pt"], localCode: "es"
        )
        #expect(groups.languages.map(\.code) == ["es", "en", "pt", SourceLanguage.multi]) // no «ja»
        #expect(groups.languages.first?.sources.map(\.name) == ["Emperor Scan", "Olympus Scanlation"])
        #expect(groups.languages.last?.sources.map(\.sourceId) == ["aidoku.multi"])
        #expect(groups.recent.isEmpty)
    }

    @Test func multiIsShownEvenWithoutActiveLanguages() {
        let groups = BrowseSourceGroups.make(installed: sources, pinnedKeys: [], recents: [:], active: [], localCode: "es")
        #expect(groups.languages.map(\.code) == [SourceLanguage.multi])
    }

    @Test func recentlyUsedAreTheLastThreeVisibleNotPinned() {
        let now = Date()
        let recents: [String: Date] = [
            "suwa.olympus": now.addingTimeInterval(-10),
            "suwa.emperor": now.addingTimeInterval(-5), // pinned: not repeated
            "aidoku.en": now.addingTimeInterval(-20),
            "aidoku.ja": now, // language not active
            "aidoku.multi": now.addingTimeInterval(-30),
            "aidoku.pt": now.addingTimeInterval(-40),
            "removed": now
        ]
        let installed = sources.filter { $0.sourceId != "suwa.emperor" }
        let groups = BrowseSourceGroups.make(
            installed: installed, pinnedKeys: ["suwa.emperor"], recents: recents, active: ["es", "en", "pt"], localCode: "es"
        )
        #expect(groups.recent.map(\.sourceId) == ["suwa.olympus", "aidoku.en", "aidoku.multi"])
        // while searching, no recents
        let searching = BrowseSourceGroups.make(
            installed: installed, pinnedKeys: [], recents: recents, active: ["es"], showRecent: false
        )
        #expect(searching.recent.isEmpty)
    }

    @Test func openingASourceIsRemembered() throws {
        let suite = "explore.recents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(SourceRecents.kept + 5) {
            SourceRecents.record("source.\(index)", at: start.addingTimeInterval(Double(index)), in: defaults)
        }
        SourceRecents.record("source.0", at: start.addingTimeInterval(1000), in: defaults) // again: latest
        let recents = SourceRecents.load(from: defaults)
        #expect(recents.count == SourceRecents.kept)
        #expect(recents["source.0"] == start.addingTimeInterval(1000))
        #expect(recents["source.1"] == nil) // the oldest went
    }
}

// MARK: B2

@Suite(.serialized) struct BrowseLanguagesTests {
    @Test func theLanguageButtonWritesTheSameSettingAsAddSource() {
        let saved = AppSettings.browse.languages.get()
        defer { AppSettings.browse.languages.set(saved) }
        BrowseLanguages.set(["es"])
        #expect(AppSettings.browse.languages.get() == ["es"])
        #expect(UserDefaults.standard.object(forKey: "Browse.languages") != nil)
        let toggled = BrowseLanguages.toggled("en", in: BrowseLanguages.active())
        #expect(toggled == ["es", "en"])
        #expect(BrowseLanguages.toggled("es", in: toggled) == ["en"])
        #expect(BrowseLanguages.toggled("pt-BR", in: []) == ["pt"])
    }

    @Test func languagesOfferedAreTheUnionWithMultiAndTheDevicesFirst() {
        let options = BrowseLanguages.options(
            installed: [["es"], ["en", "es"], ["ja"]],
            external: ["en", "fr", "multi"],
            server: ["es", "all", "pt-BR", "zh"],
            localCode: "es"
        )
        #expect(options.first == SourceLanguage.multi)
        #expect(options.dropFirst().first == "es")
        #expect(Set(options) == [SourceLanguage.multi, "es", "en", "ja", "fr", "pt", "zh"])
        #expect(options.count == 7) // no repeats
        let rest = Array(options.dropFirst(2))
        #expect(rest == rest.sorted { SourceLanguage.compare($0, $1) == .orderedAscending })
    }

    @Test func allAndMultiAreAlwaysVisible() {
        #expect(BrowseLanguages.code("all") == SourceLanguage.multi)
        #expect(BrowseLanguages.isVisible(["all"], active: []))
        #expect(BrowseLanguages.isVisible(["en", "es"], active: []))
        #expect(BrowseLanguages.isVisible(["es"], active: ["es"]))
        #expect(!BrowseLanguages.isVisible(["es"], active: ["en"]))
        #expect(BrowseLanguages.isVisible(["pt-BR"], active: ["pt"]))
    }
}

// MARK: B3

private func extensionsFixture() throws -> [ServerExtension] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Suwayomi/suwayomi-extensions.json")
    struct Response: Decodable {
        struct DataContainer: Decodable {
            struct Nodes: Decodable { let nodes: [ServerExtension] }
            let extensions: Nodes
        }
        let data: DataContainer
    }
    return try JSONDecoder().decode(Response.self, from: Data(contentsOf: url)).data.extensions.nodes
}

/// A fake server: records what it's asked and how many at once.
final class FakeExtensionsServer: ServerExtensionsAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var extensions: [ServerExtension]
    private(set) var applied: [String] = []
    private(set) var maxConcurrent = 0
    private var running = 0
    var fails = false
    var delay: UInt64 = 0

    init(_ extensions: [ServerExtension]) {
        self.extensions = extensions
    }

    func list() async throws -> [ServerExtension] {
        if fails { throw URLError(.cannotConnectToHost) }
        return lock.withLock { extensions }
    }

    func fetch() async throws -> [ServerExtension] { try await list() }

    func apply(_ action: ServerExtensionAction, to pkgName: String) async throws {
        lock.withLock {
            running += 1
            maxConcurrent = max(maxConcurrent, running)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        lock.withLock {
            running -= 1
            applied.append("\(action.rawValue) \(pkgName)")
            if let index = extensions.firstIndex(where: { $0.pkgName == pkgName }) {
                extensions[index].isInstalled = action != .uninstall
                extensions[index].hasUpdate = false
            }
        }
    }

    func apply(_ action: ServerExtensionAction, to pkgNames: [String]) async throws {
        for pkgName in pkgNames {
            try await apply(action, to: pkgName)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

struct ServerExtensionsTests {
    @Test func theServersExtensionsDecode() throws {
        let extensions = try extensionsFixture()
        #expect(extensions.count == 20)
        #expect(extensions.filter(\.isInstalled).count == 8)
        let olympus = try #require(extensions.first { $0.name == "Olympus Scanlation" })
        #expect(olympus.lang == "es")
        #expect(olympus.serverSourceIds == ["1596411039134168890"])
        #expect(olympus.iconUrl.hasPrefix("/api/v1/extension/icon/"))
        #expect(extensions.contains { $0.isNsfw })
        #expect(extensions.contains { $0.isPartlyNsfw })
        #expect(extensions.contains { $0.isMultiLanguage })
        #expect(extensions.allSatisfy { $0.contentWarning != .unknown })
    }

    @Test func sectionsAreUpdatesInstalledAndAvailableByActiveLanguage() throws {
        var extensions = try extensionsFixture()
        let index = try #require(extensions.firstIndex { $0.name == "Manga Crab" })
        extensions[index].hasUpdate = true
        let sections = ServerExtensionSections.make(extensions, active: ["es"], localCode: "es")
        #expect(sections.updates.map(\.name) == ["Manga Crab"])
        #expect(sections.installed.count == 7)
        #expect(!sections.installed.contains { $0.name == "Manga Crab" })
        // available: Spanish first, «all» (multi) always, no English nor Portuguese
        #expect(sections.available.map(\.code) == ["es", SourceLanguage.multi])
        #expect(sections.available.first?.extensions.map(\.name) == ["AnzManga", "BarManga", "LectorManga.lat", "LectorXD"])
        // another language active
        let more = ServerExtensionSections.make(extensions, active: ["es", "en", "pt"], localCode: "es")
        #expect(more.available.map(\.code) == ["es", "en", "pt", SourceLanguage.multi])
    }

    @Test func theSearchNarrowsEverySectionByName() throws {
        let extensions = try extensionsFixture()
        let sections = ServerExtensionSections.make(extensions, active: ["es"], query: "lector", localCode: "es")
        #expect(sections.updates.isEmpty && sections.installed.isEmpty)
        #expect(sections.available.flatMap(\.extensions).map(\.name) == ["LectorManga.lat", "LectorXD"])
        let accents = ServerExtensionSections.make(extensions, active: ["es"], query: "OLÝMPUS", localCode: "es")
        #expect(accents.installed.map(\.name) == ["Olympus Scanlation"])
        #expect(ServerExtensionSections.make(extensions, active: ["es"], query: "zzz").isEmpty)
    }

    @MainActor
    @Test func installingAsksTheServerThenResyncsTheSources() async throws {
        let server = FakeExtensionsServer(try extensionsFixture())
        let resyncs = Counter()
        let model = ServerExtensionsModel(api: server, resync: { resyncs.add() }, libraryCount: { _ in .init() })
        await model.load()
        #expect(model.state == .loaded)
        let lector = try #require(model.extensions.first { $0.name == "LectorManga.lat" })
        await model.perform(.install, on: lector)
        #expect(server.applied == ["install \(lector.pkgName)"])
        #expect(resyncs.count == 1)
        #expect(model.extensions.first { $0.pkgName == lector.pkgName }?.isInstalled == true)
        #expect(model.busy.isEmpty)
        await model.perform(.uninstall, on: lector)
        #expect(server.applied.last == "uninstall \(lector.pkgName)")
        #expect(resyncs.count == 2)
    }

    @MainActor
    @Test func atMostTwoInstallsAtOnce() async throws {
        let server = FakeExtensionsServer(try extensionsFixture())
        server.delay = 200_000_000
        let model = ServerExtensionsModel(api: server, resync: {}, libraryCount: { _ in .init() })
        await model.load()
        let available = model.extensions.filter { !$0.isInstalled }.prefix(5)
        await withTaskGroup(of: Void.self) { group in
            for ext in available {
                group.addTask { await model.perform(.install, on: ext) }
            }
        }
        #expect(server.applied.count == 5)
        #expect(server.maxConcurrent == 2)
    }

    @MainActor
    @Test func updatingAllUpdatesThePendingOnes() async throws {
        var extensions = try extensionsFixture()
        for name in ["Manga Crab", "MHScans"] {
            let index = try #require(extensions.firstIndex { $0.name == name })
            extensions[index].hasUpdate = true
        }
        let server = FakeExtensionsServer(extensions)
        let resyncs = Counter()
        let model = ServerExtensionsModel(api: server, resync: { resyncs.add() }, libraryCount: { _ in .init() })
        await model.load()
        await model.updateAll()
        #expect(server.applied.count == 2)
        #expect(server.applied.allSatisfy { $0.hasPrefix("update ") })
        #expect(resyncs.count == 1)
        #expect(!model.extensions.contains { $0.hasUpdate })
    }

    @MainActor
    @Test func aServerDownOrNoConnectionIsSaid() async throws {
        let server = FakeExtensionsServer(try extensionsFixture())
        server.fails = true
        let model = ServerExtensionsModel(api: server, resync: {}, libraryCount: { _ in .init() })
        await model.load()
        #expect(model.state == .failed)
        server.fails = false
        await model.load() // Reintentar
        #expect(model.state == .loaded)
        let none = ServerExtensionsModel(api: nil, resync: {}, libraryCount: { _ in .init() })
        await none.load()
        #expect(none.state == .noConnection)
    }
}

// MARK: B4

struct MigrateSourcesGroupingTests {
    @Test func eachServerSourceCountsOnItsOwn() {
        let manga: [AidokuRunner.Manga] = [
            .init(sourceKey: "suwayomi.suwa.1596411039134168890", key: "1", title: "A"),
            .init(sourceKey: "suwayomi.suwa.1596411039134168890", key: "2", title: "B"),
            .init(sourceKey: "suwayomi.suwa.4562754350961964148", key: "3", title: "C"),
            .init(sourceKey: "suwayomi.suwa", key: "4", title: "Pendiente"),
            .init(sourceKey: "aidoku.en", key: "5", title: "D")
        ]
        let groups = MigrateSourcesView.group(manga)
        #expect(groups.mapValues(\.count) == [
            "suwayomi.suwa.1596411039134168890": 2,
            "suwayomi.suwa.4562754350961964148": 1,
            "suwayomi.suwa": 1,
            "aidoku.en": 1
        ])
    }
}
