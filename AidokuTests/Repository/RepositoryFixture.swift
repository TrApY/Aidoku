//
//  RepositoryFixture.swift
//  AidokuTests
//
//  SUWA-13 F4: the contract tests run against every fixture (Core Data now; SwiftData in F19), each test on a
//  store of its own that is removed at the end. Never the app's store.
//

import CoreData
import Foundation
import Testing

@testable import Aidoku

/// A store with its repositories, and how to remove it.
struct FixtureStore: Sendable {
    let repos: DataRepositories
    let tearDown: @Sendable () async -> Void
}

protocol RepositoryFixture: Sendable, CustomTestStringConvertible {
    func make() async throws -> FixtureStore
}

/// Every fixture the contract tests run against.
let repositoryFixtures: [any RepositoryFixture] = [CoreDataFixture()]

/// A Core Data store in a temporary folder (the pattern of ConversionStore): the app's model and its Cloud and
/// Local configurations, persistent history on, synchronous loading. The model is the app's own instance
/// (`CoreDataManager.shared.container.managedObjectModel`): the test host app already loads its store at launch
/// (AppDelegate), and a second model instance would make the entity classes (TrackObject…) ambiguous.
struct CoreDataFixture: RepositoryFixture {
    var testDescription: String { "Core Data" }

    func make() async throws -> FixtureStore {
        let store = try Self.container()
        let repos = DataRepositories(container: store.container)
        return FixtureStore(repos: repos) { Self.remove(store.container, directory: store.directory) }
    }

    static func container() throws -> (container: NSPersistentContainer, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = NSPersistentContainer(name: "Aidoku", managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        let cloud = NSPersistentStoreDescription(url: directory.appendingPathComponent("Aidoku.sqlite"))
        cloud.configuration = "Cloud"
        cloud.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloud.shouldAddStoreAsynchronously = false
        let local = NSPersistentStoreDescription(url: directory.appendingPathComponent("Local.sqlite"))
        local.configuration = "Local"
        local.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [cloud, local]
        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error { loadError = error }
        }
        if let loadError { throw loadError }
        return (container, directory)
    }

    static func remove(_ container: NSPersistentContainer, directory: URL) {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct RepositoryFixtureTests {
    /// The fixture's store is its own folder, never the app's, and it is gone after tearDown.
    @Test func theCoreDataFixtureIsIsolated() async throws {
        let store = try CoreDataFixture.container()
        let urls = store.container.persistentStoreCoordinator.persistentStores.compactMap(\.url)
        #expect(urls.count == 2)
        #expect(urls.allSatisfy { $0.path.hasPrefix(store.directory.path) })
        let app = CoreDataManager.shared.container.persistentStoreCoordinator.persistentStores.compactMap(\.url)
        #expect(Set(urls).isDisjoint(with: app))
        CoreDataFixture.remove(store.container, directory: store.directory)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }
}
