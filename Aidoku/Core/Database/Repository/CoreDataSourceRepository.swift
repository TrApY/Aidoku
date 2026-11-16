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
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getSources(context: context).map { $0.toRecord() }
        }
    }

    func record(key: String) async -> SourceRecord? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getSource(key: key, context: context)?.toRecord()
        }
    }

    func contains(key: String) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasSource(key: key, context: context)
        }
    }

    func add(_ source: AidokuRunner.Source, customSource: Data?) async -> Bool {
        await container.performBackgroundTask { context in
            let result = CoreDataManager.shared.createSource(source: source, context: context)
            if let customSource {
                result.customSource = customSource as NSObject
            }
            return (try? context.save()) != nil
        }
    }

    func save(_ source: AidokuRunner.Source, customSource: Data) async -> Bool {
        await container.performBackgroundTask { context in
            let object = CoreDataManager.shared.getSource(key: source.key, context: context)
                ?? CoreDataManager.shared.createSource(source: source, context: context)
            object.customSource = customSource as NSObject
            return context.saveLogging("Failed to save source \(source.key)")
        }
    }

    func replace(with source: AidokuRunner.Source) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.removeSource(key: source.key, context: context)
            CoreDataManager.shared.createSource(source: source, context: context)
            return (try? context.save()) != nil
        }
    }

    func setCustomSource(key: String, data: Data) async -> SourceRecord? {
        await container.performBackgroundTask { context in
            let source = CoreDataManager.shared.getSource(key: key, context: context)
            source?.customSource = data as NSObject
            try? context.save()
            return source?.toRecord()
        }
    }

    func remove(key: String) async -> SourceRecord? {
        await container.performBackgroundTask { context in
            let data = CoreDataManager.shared.getSource(key: key, context: context)?.toRecord()
            if data != nil {
                CoreDataManager.shared.removeSource(key: key, context: context)
                try? context.save()
            }
            return data
        }
    }

    func removeDuplicate(_ record: SourceRecord) async -> Bool {
        await container.performBackgroundTask { context in
            let request = SourceObject.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", record.id)
            guard let object = ((try? context.fetch(request)) ?? []).last(where: { $0.toRecord() == record }) else {
                return false
            }
            context.delete(object)
            return (try? context.save()) != nil
        }
    }

    func clear() async -> [SourceRecord] {
        await container.performBackgroundTask { context in
            let objects = CoreDataManager.shared.getSources(context: context).map { $0.toRecord() }
            CoreDataManager.shared.clearSources(context: context)
            try? context.save()
            return objects
        }
    }

    func listing(of key: String) async -> Int? {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getSource(key: key, context: context).map { Int($0.listing) }
        }
    }

    func setListing(_ listing: Int, of key: String) async -> Bool {
        await container.performBackgroundTask { context in
            guard
                listing >= 0,
                listing < Int16.max,
                let source = CoreDataManager.shared.getSource(key: key, context: context)
            else { return false }
            source.listing = Int16(listing)
            return context.saveLogging("CoreDataManager.setListing")
        }
    }
}
