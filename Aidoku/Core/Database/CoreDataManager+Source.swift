//
//  CoreDataManager+Source.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 1/3/23.
//

import CoreData
import AidokuRunner

extension CoreDataManager {
    /// Remove all source objects.
    func clearSources(context: NSManagedObjectContext) {
        clear(request: SourceObject.fetchRequest(), context: context)
    }

    /// Gets all source objects.
    func getSources(context: NSManagedObjectContext) -> [SourceObject] {
        (try? context.fetch(SourceObject.fetchRequest())) ?? []
    }

    /// Check if a source exists in the data store.
    func hasSource(key: String, context: NSManagedObjectContext) -> Bool {
        let request = SourceObject.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", key)
        request.fetchLimit = 1
        return (try? context.count(for: request)) ?? 0 > 0
    }

    /// Get a particular source object.
    func getSource(key: String, context: NSManagedObjectContext) -> SourceObject? {
        let request = SourceObject.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", key)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    /// Creates a new source item.
    @discardableResult
    func createSource(source: AidokuRunner.Source, context: NSManagedObjectContext) -> SourceObject {
        let object = SourceObject(context: context)
        object.load(from: source)
        return object
    }

    /// Removes a source object.
    func removeSource(key: String, context: NSManagedObjectContext) {
        guard let object = getSource(key: key, context: context) else { return }
        context.delete(object)
    }
}
