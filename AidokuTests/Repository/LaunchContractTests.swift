//
//  LaunchContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L12b (D-L12-10): the PlayCover fix forces the Core Data stack to be created on the main thread at
//  launch, before any background task touches it. It now does it through the repositories, and that still creates
//  the stack: DataRepositories.shared is a stored constant built on the manager's container.
//

import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite struct LaunchContractTests {
    private func source(_ path: String) throws -> String {
        try String(contentsOf: ArchitectureLintTests.root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func theLaunchCreatesTheStackThroughTheRepositories() throws {
        let app = try source("Aidoku/App/AppDelegate.swift")
        let fix = try #require(app.range(of: "// PlayCover fix:"))
        // the first statement after the fix's comment (the rest of its first line is comment too)
        let statement = app[fix.upperBound...]
            .split(separator: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("//") && !$0.isEmpty }
        #expect(statement == "_ = DataRepositories.shared")
        // and DataRepositories.shared builds the manager's shared instance, container included, when first touched
        let repositories = try source("Aidoku/Core/Database/Repository/CoreDataRepositories.swift")
        #expect(repositories.contains("static let shared = DataRepositories(container: CoreDataManager.shared.container)"))
        _ = DataRepositories.shared
        #expect(CoreDataManager.shared.container.persistentStoreCoordinator.persistentStores.count == 2)
    }
}
