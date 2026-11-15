//
//  ServerExtensionsConcurrencyTests.swift
//  AidokuTests
//
//  SUWA-12 D B3: «Actualizar todo» runs once and counts in the limit of 2; an old list never paints over
//  a newer one.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

/// fetch (pull to refresh) answers late with the list before an install; list answers at once after it.
private final class LateRefreshServer: ServerExtensionsAPI, @unchecked Sendable {
    let before: [ServerExtension]
    let after: [ServerExtension]

    init(before: [ServerExtension], after: [ServerExtension]) {
        self.before = before
        self.after = after
    }

    func list() async throws -> [ServerExtension] { after }

    func fetch() async throws -> [ServerExtension] {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return before
    }

    func apply(_ action: ServerExtensionAction, to pkgName: String) async throws {}
    func apply(_ action: ServerExtensionAction, to pkgNames: [String]) async throws {}
}

@MainActor
@Suite(.serialized) struct ServerExtensionsConcurrencyTests {
    private func extensions() throws -> [ServerExtension] {
        [
            try serverExtension("Crab", hasUpdate: true, sourceId: "1"),
            try serverExtension("Scans", hasUpdate: true, sourceId: "2"),
            try serverExtension("Lector", installed: false, sourceId: "3"),
            try serverExtension("Barmanga", installed: false, sourceId: "4")
        ]
    }

    @Test func updatingAllTwiceRunsOnce() async throws {
        let server = FakeExtensionsServer(try extensions())
        server.delay = 200_000_000
        let model = ServerExtensionsModel(api: server, resync: {}, libraryCount: { _ in .init() })
        await model.load()
        let first = Task { await model.updateAll() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.isUpdatingAll) // the button is disabled
        await model.updateAll() // a second tap
        await first.value
        #expect(server.applied.count == 2)
        #expect(!model.isUpdatingAll)
    }

    @Test func updatingAllCountsInTheLimitOfTwo() async throws {
        let server = FakeExtensionsServer(try extensions())
        server.delay = 200_000_000
        let model = ServerExtensionsModel(api: server, resync: {}, libraryCount: { _ in .init() })
        await model.load()
        let available = model.extensions.filter { !$0.isInstalled }
        await withTaskGroup(of: Void.self) { group in
            for ext in available {
                group.addTask { await model.perform(.install, on: ext) }
            }
            group.addTask { await model.updateAll() }
        }
        #expect(server.applied.count == 4)
        #expect(server.maxConcurrent <= 2)
    }

    @Test func aLateRefreshDoesNotPaintAnOldList() async throws {
        let before = try serverExtension("Lector", installed: false)
        let after = try serverExtension("Lector", installed: true)
        let model = ServerExtensionsModel(
            api: LateRefreshServer(before: [before], after: [after]), resync: {}, libraryCount: { _ in .init() }
        )
        let refresh = Task { await model.load(refresh: true) } // pulled before the install ended
        try await Task.sleep(nanoseconds: 50_000_000)
        await model.load() // the install ended: the list again
        await refresh.value
        #expect(model.extensions.first?.isInstalled == true)
    }
}
