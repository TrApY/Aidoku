//
//  CoreDataSourceRepository.swift
//  Aidoku
//

import AidokuRunner
import CoreData

/// Not an actor (D5): each call runs on its own background context, as SourceManager did before.
final class CoreDataSourceRepository: SourceRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func all() async -> [SourceRecord] {
        []
    }

    func record(key: String) async -> SourceRecord? {
        nil
    }

    func contains(key: String) async -> Bool {
        false
    }

    func add(_ source: AidokuRunner.Source, customSource: Data?) async -> Bool {
        false
    }

    func save(_ source: AidokuRunner.Source, customSource: Data) async -> Bool {
        false
    }

    func replace(with source: AidokuRunner.Source) async -> Bool {
        false
    }

    func setCustomSource(key: String, data: Data) async -> SourceRecord? {
        nil
    }

    func remove(key: String) async -> SourceRecord? {
        nil
    }

    func removeDuplicate(_ record: SourceRecord) async -> Bool {
        false
    }

    func clear() async -> [SourceRecord] {
        []
    }

    func listing(of key: String) async -> Int? {
        nil
    }

    func setListing(_ listing: Int, of key: String) async -> Bool {
        false
    }
}
