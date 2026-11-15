//
//  SuwayomiServerSourceSyncTests.swift
//  AidokuTests
//
//  SUWA-12 D4 (T4): the children of a connection follow the server's source list.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

private final class SyncFixtureToken {}

private func spanishSources() throws -> [SuwayomiServerSource] {
    let name = "suwayomi-sources-es"
    let url = Bundle(for: SyncFixtureToken.self).url(forResource: name, withExtension: "json")
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Suwayomi/\(name).json")
    return try JSONDecoder().decode(SuwayomiSourcesResponse.self, from: Data(contentsOf: url)).data.sources.nodes
}

/// Records what the sync saves.
private final class SavedConfigs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SuwayomiServerSourceConfig] = []
    var all: [SuwayomiServerSourceConfig] { lock.withLock { values } }
    func save(_ config: SuwayomiServerSourceConfig) -> Bool {
        lock.withLock { values.append(config) }
        return true
    }
}

@Suite(.serialized) struct SuwayomiServerSourceSyncTests {
    let parent = "suwayomi.synctest"
    let olympus = "1596411039134168890"
    let emperor = "4562754350961964148"

    private func server(_ ids: [String], from all: [SuwayomiServerSource]) -> [SuwayomiServerSource] {
        all.filter { ids.contains($0.id) }
    }

    @Test func everySourceOfTheServerIsAddedButTheLocalOne() throws {
        let all = try spanishSources()
        let local = SuwayomiServerSource(id: "0", name: "Local source", lang: "localsourcelang", displayName: "Local source", isNsfw: false, supportsLatest: true, iconUrl: nil)
        let plan = SuwayomiServerSourceSync.plan(parentKey: parent, existing: [], server: all + [local])
        #expect(all.contains { $0.id == "0" }) // the answer has the local source
        #expect(plan.count == all.filter { $0.id != "0" }.count)
        #expect(!plan.contains { $0.serverSourceId == "0" })
        #expect(plan.allSatisfy { $0.parentKey == parent && $0.key == "\(parent).\($0.serverSourceId)" && $0.available })
        let olympusConfig = try #require(plan.first { $0.serverSourceId == olympus })
        #expect(olympusConfig.name == "Olympus Scanlation")
        #expect(plan.first { $0.serverSourceId == emperor }?.isNsfw == true)
        // nothing new: nothing to save
        #expect(SuwayomiServerSourceSync.plan(parentKey: parent, existing: plan, server: all).isEmpty)
    }

    @Test func aSourceGoneFromTheServerIsOnlyMarkedAndComesBack() throws {
        let all = try spanishSources()
        let both = SuwayomiServerSourceSync.plan(parentKey: parent, existing: [], server: server([olympus, emperor], from: all))
        // Emperor uninstalled on the server: marked unavailable, not removed
        let gone = SuwayomiServerSourceSync.plan(parentKey: parent, existing: both, server: server([olympus], from: all))
        #expect(gone.map(\.serverSourceId) == [emperor])
        #expect(gone.first?.available == false)
        let afterGone = both.map { config in gone.first { $0.key == config.key } ?? config }
        // still gone: nothing to save again
        #expect(SuwayomiServerSourceSync.plan(parentKey: parent, existing: afterGone, server: server([olympus], from: all)).isEmpty)
        // installed again: back
        let back = SuwayomiServerSourceSync.plan(parentKey: parent, existing: afterGone, server: server([olympus, emperor], from: all))
        #expect(back.map(\.serverSourceId) == [emperor])
        #expect(back.first?.available == true)
        // another connection's children are not touched
        let other = SuwayomiServerSourceConfig(parentKey: "suwayomi.otra", server: all[0])
        #expect(SuwayomiServerSourceSync.plan(parentKey: parent, existing: both + [other], server: server([olympus, emperor], from: all)).isEmpty)
    }

    @Test func changesOnTheServerAreSaved() throws {
        let all = try spanishSources()
        let first = SuwayomiServerSourceSync.plan(parentKey: parent, existing: [], server: server([olympus], from: all))
        let source = try #require(server([olympus], from: all).first)
        let renamed = SuwayomiServerSource(
            id: source.id, name: "Olympus", lang: source.lang, displayName: "Olympus (ES)",
            isNsfw: true, supportsLatest: false, iconUrl: "/api/v1/extension/icon/nuevo"
        )
        let plan = SuwayomiServerSourceSync.plan(parentKey: parent, existing: first, server: [renamed])
        #expect(plan.count == 1)
        #expect(plan.first?.name == "Olympus")
        #expect(plan.first?.isNsfw == true)
        #expect(plan.first?.supportsLatest == false)
        #expect(plan.first?.iconUrl == "/api/v1/extension/icon/nuevo")
    }

    @Test func aServerThatDoesntAnswerChangesNothing() async throws {
        let saved = SavedConfigs()
        let existing = SuwayomiServerSourceSync.plan(parentKey: parent, existing: [], server: try spanishSources())
        let result = await SuwayomiServerSourceSync.sync(
            parentKey: parent,
            existing: existing,
            fetch: { throw URLError(.timedOut) },
            save: { saved.save($0) }
        )
        #expect(!result.answered)
        #expect(saved.all.isEmpty) // not even «unavailable»
        // and an answer adds and marks as planned
        let answer = try spanishSources().filter { $0.id != emperor }
        let synced = await SuwayomiServerSourceSync.sync(
            parentKey: parent,
            existing: existing,
            fetch: { answer },
            save: { saved.save($0) }
        )
        #expect(synced == .init(answered: true, added: 0, updated: 0, unavailable: 1))
        #expect(saved.all.map(\.serverSourceId) == [emperor])
    }

    @Test func aGoneSourceKeepsItsSettingsAndTracking() async throws {
        let all = try spanishSources()
        let configs = SuwayomiServerSourceSync.plan(parentKey: parent, existing: [], server: server([olympus, emperor], from: all))
        let emperorKey = "\(parent).\(emperor)"
        let mangaId = MangaIdentifier(sourceKey: emperorKey, mangaKey: "897")
        defer { UserDefaults.standard.removeObject(forKey: "\(emperorKey).filters") }
        for config in configs {
            #expect(await SourceManager.shared.addOrUpdateCustomSource(config: .suwayomiServerSource(config)))
        }
        UserDefaults.standard.set(Data([1]), forKey: "\(emperorKey).filters")
        await CoreDataManager.shared.container.performBackgroundTask { context in
            _ = CoreDataManager.shared.createTrack(id: "\(emperorKey)|897", trackerId: "suwayomi", mangaId: mangaId, title: nil, context: context)
            try? context.save()
        }
        let result = await SuwayomiServerSourceSync.sync(
            parentKey: parent,
            existing: configs,
            fetch: { server([olympus], from: all) },
            save: { await SourceManager.shared.addOrUpdateCustomSource(config: .suwayomiServerSource($0)) }
        )
        #expect(result.unavailable == 1)
        #expect(UserDefaults.standard.data(forKey: "\(emperorKey).filters") == Data([1]))
        let tracked = await CoreDataManager.shared.container.performBackgroundTask { context in
            let has = CoreDataManager.shared.hasTrack(trackerId: "suwayomi", mangaId: mangaId, context: context)
            CoreDataManager.shared.removeTrack(trackerId: "suwayomi", mangaId: mangaId, context: context)
            try? context.save()
            return has
        }
        #expect(tracked)
        // still a source (its manga open) but not offered
        #expect(await SourceManager.shared.source(for: emperorKey) != nil)
        #expect(!SuwayomiConnections.shared.isListed(emperorKey))
        #expect(SuwayomiConnections.shared.isListed("\(parent).\(olympus)"))
        let listed = await SourceManager.shared.getLoadedSources(listedOnly: true).map(\.key)
        #expect(!listed.contains(emperorKey))
        #expect(listed.contains("\(parent).\(olympus)"))
        for config in configs {
            await SourceManager.shared.remove(sourceKey: config.key)
        }
    }
}
