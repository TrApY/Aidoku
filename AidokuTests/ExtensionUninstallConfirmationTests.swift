//
//  ExtensionUninstallConfirmationTests.swift
//  AidokuTests
//
//  SUWA-12 D M1: removing an extension asks twice whenever the library may have manga from it.
//

import CoreData
import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

private struct CountFailed: Error {}

func serverExtension(
    _ name: String, pkg: String? = nil, installed: Bool = true, hasUpdate: Bool = false, sourceId: String = "1596411039134168890"
) throws -> ServerExtension {
    let json = """
    {"pkgName":"\(pkg ?? "eu.kanade.tachiyomi.extension.es.\(name.lowercased())")","name":"\(name)","lang":"es",\
    "versionName":"1.0","isInstalled":\(installed),"hasUpdate":\(hasUpdate),"isObsolete":false,\
    "iconUrl":"/api/v1/extension/icon/\(name).apk","contentWarning":"SAFE","source":{"nodes":[{"id":"\(sourceId)"}]}}
    """
    return try JSONDecoder().decode(ServerExtension.self, from: Data(json.utf8))
}

@MainActor
struct ExtensionUninstallConfirmationTests {
    private func check(_ count: @escaping @Sendable ([String]) async throws -> ServerExtensionLibraryCount) async throws -> ServerExtensionUninstallCheck {
        let model = ServerExtensionsModel(api: nil, resync: {}, libraryCount: count)
        return await model.uninstallCheck(of: try serverExtension("Olympus"))
    }

    @Test func mangaUnderItsSourcesAskTwice() async throws {
        #expect(try await check { _ in .init(inSources: 3) } == .init(confirmations: 2, count: 3))
    }

    @Test func mangaStillUnderTheConnectionAskTwice() async throws {
        #expect(try await check { _ in .init(inSources: 0, pendingUnderConnection: 2) } == .init(confirmations: 2, count: nil))
    }

    @Test func aCountThatFailsAsksTwice() async throws {
        #expect(try await check { _ in throw CountFailed() } == .init(confirmations: 2, count: nil))
    }

    @Test func nothingInTheLibraryAsksOnce() async throws {
        #expect(try await check { _ in .init() } == .init(confirmations: 1, count: 0))
    }

    @Test func theRealCountSeesTheMangaStillUnderTheConnection() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        let connection = "suwayomi.unins"
        let olympus = "\(connection).1596411039134168890"
        let context = store.container.newBackgroundContext()
        try context.performAndWait {
            func manga(_ sourceId: String, _ id: String, library: Bool) {
                let object = store.insert("Manga", [
                    "sourceId": sourceId, "id": id, "title": "Manga \(id)", "neverUpdate": false, "chapterFlags": Int16(0),
                    "editedKeys": Int32(0), "nsfw": Int16(0), "status": Int16(0), "viewer": Int16(0)
                ], in: context)
                if library {
                    store.insert("LibraryManga", ["dateAdded": Date(), "manga": object], in: context)
                }
            }
            manga(olympus, "1", library: true)
            manga(olympus, "2", library: false) // not in the library
            manga("\(connection).4562754350961964148", "3", library: true) // another extension
            manga(connection, "4", library: true) // not converted yet
            try context.save()
        }
        let count = try await ServerExtensionsModel.countLibrary(
            repos: DataRepositories(container: store.container), connection: connection, serverSourceIds: ["1596411039134168890"]
        )
        #expect(count == .init(inSources: 1, pendingUnderConnection: 1))
        let repos = DataRepositories(container: store.container)
        let result = try await check { ids in
            try await ServerExtensionsModel.countLibrary(repos: repos, connection: connection, serverSourceIds: ids)
        }
        #expect(result == .init(confirmations: 2, count: nil))
    }
}
