//
//  SuwayomiSourceConversionTests.swift
//  AidokuTests
//
//  SUWA-12 D6: the library under the single Suwayomi source (the parent) moves to each manga's server
//  source without losing anything. On a store of its own (a temporary folder with the app's model and
//  its Cloud/Local configurations, no CloudKit), never the app's.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

/// A store in a temporary folder with the app's model (the same model instance: one class per entity).
final class ConversionStore: @unchecked Sendable {
    let directory: URL
    let container: NSPersistentContainer
    let downloads: URL
    let defaults: UserDefaults
    let domain: String

    /// - copyFrom: a folder with Aidoku.sqlite(-wal,-shm) and Local.sqlite(-wal,-shm) to open a COPY of.
    init(copyFrom: URL? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("suwa12-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let copyFrom {
            for name in ["Aidoku.sqlite", "Aidoku.sqlite-wal", "Aidoku.sqlite-shm", "Local.sqlite", "Local.sqlite-wal", "Local.sqlite-shm"] {
                let source = copyFrom.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
                }
            }
        }
        let model = CoreDataManager.shared.container.managedObjectModel
        container = NSPersistentContainer(name: "Aidoku", managedObjectModel: model)
        let cloud = NSPersistentStoreDescription(url: directory.appendingPathComponent("Aidoku.sqlite"))
        cloud.configuration = "Cloud"
        cloud.shouldMigrateStoreAutomatically = true
        cloud.shouldInferMappingModelAutomatically = true
        cloud.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey) // as the app (else read-only)
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
        downloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        domain = "suwa12.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: domain)!
    }

    func close() {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    }

    func environment(
        resolve: @escaping @Sendable (String, [String]) async throws -> [String: String],
        children: [SuwayomiServerSourceConfig],
        backup: @escaping @Sendable () async -> Bool = { true }
    ) -> SuwayomiSourceConversion.Environment {
        .init(
            container: container,
            defaults: defaults,
            defaultsDomain: domain,
            downloadsDirectory: downloads,
            resolve: resolve,
            children: { parent in children.filter { $0.parentKey == parent } },
            backup: backup
        )
    }

    // MARK: Data

    @discardableResult
    func insert(_ entity: String, _ values: [String: Any], in context: NSManagedObjectContext) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        for (key, value) in values {
            object.setValue(value, forKey: key)
        }
        return object
    }

    /// Every object of the Cloud entities, as comparable text: attributes (sourceId through `key`) and
    /// relationships by the identity of the other side.
    func snapshot(key: (String) -> String = { $0 }) -> [String: [String]] {
        let context = container.newBackgroundContext()
        return context.performAndWait {
            var result: [String: [String]] = [:]
            for entity in ["Manga", "Chapter", "History", "MangaUpdate", "Track", "Vocab", "LibraryManga", "Category", "ReadingSession"] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                let objects = (try? context.fetch(request)) ?? []
                result[entity] = objects.map { describe($0, key: key) }.sorted()
            }
            return result
        }
    }

    private func describe(_ object: NSManagedObject, key: (String) -> String) -> String {
        var parts: [String] = []
        for name in object.entity.attributesByName.keys.sorted() {
            var value = object.value(forKey: name)
            if name == "sourceId", let sourceId = value as? String {
                value = key(sourceId)
            }
            if let date = value as? Date { value = date.timeIntervalSince1970 }
            if let data = value as? Data { value = data.base64EncodedString() }
            parts.append("\(name)=\(value.map { "\($0)" } ?? "nil")")
        }
        for name in object.entity.relationshipsByName.keys.sorted() {
            let value = object.value(forKey: name)
            if let set = value as? Set<NSManagedObject> {
                parts.append("\(name)=[\(set.map { identity($0, key: key) }.sorted().joined(separator: ","))]")
            } else if let other = value as? NSManagedObject {
                parts.append("\(name)=\(identity(other, key: key))")
            } else {
                parts.append("\(name)=nil")
            }
        }
        return parts.joined(separator: " ")
    }

    private func identity(_ object: NSManagedObject, key: (String) -> String) -> String {
        let entity = object.entity.name ?? "?"
        switch entity {
            case "Manga": return "Manga(\(key(object.value(forKey: "sourceId") as? String ?? "")),\(object.value(forKey: "id") ?? ""))"
            case "Chapter": return "Chapter(\(key(object.value(forKey: "sourceId") as? String ?? "")),\(object.value(forKey: "mangaId") ?? ""),\(object.value(forKey: "id") ?? ""))"
            case "History": return "History(\(key(object.value(forKey: "sourceId") as? String ?? "")),\(object.value(forKey: "mangaId") ?? ""),\(object.value(forKey: "chapterId") ?? ""))"
            case "Category": return "Category(\(object.value(forKey: "title") ?? ""))"
            case "LibraryManga":
                let manga = object.value(forKey: "manga") as? NSManagedObject
                return "Library(\(manga.map { identity($0, key: key) } ?? "nil"))"
            case "ReadingSession": return "Session(\((object.value(forKey: "startDate") as? Date)?.timeIntervalSince1970 ?? 0))"
            default: return entity
        }
    }

    func count(_ entity: String, sourceId: String) -> Int {
        let context = container.newBackgroundContext()
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "sourceId == %@", sourceId)
            return (try? context.count(for: request)) ?? 0
        }
    }
}

/// Counts the backups asked.
final class BackupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func asked() { lock.withLock { value += 1 } }
}

@Suite(.serialized) struct SuwayomiSourceConversionTests {
    let parent = "suwayomi.convtest"
    let sourceA = "1596411039134168890" // Olympus
    let sourceB = "4562754350961964148" // Emperor
    let date1 = Date(timeIntervalSince1970: 1_763_000_000)
    let date2 = Date(timeIntervalSince1970: 1_763_100_000)

    var childA: String { "\(parent).\(sourceA)" }
    var childB: String { "\(parent).\(sourceB)" }

    private var children: [SuwayomiServerSourceConfig] {
        [sourceA, sourceB].map { id in
            .init(
                key: "\(parent).\(id)", parentKey: parent, serverSourceId: id, name: id, lang: "es",
                iconUrl: "", isNsfw: false, supportsLatest: true, available: true
            )
        }
    }

    /// m1, m2 in A, m3 in B; m4 unknown to the server; «1» of another source.
    private let serverMap = ["101": "1596411039134168890", "102": "1596411039134168890", "103": "4562754350961964148"]
    private var expectedKey: [String: String] { ["101": childA, "102": childA, "103": childB] }

    /// The library of the parent: 3 manga of 2 server sources, 1 the server doesn't know, and 1 of another
    /// source; read chapters, one unfinished (page and total), reading dates, categories, track, update,
    /// vocabulary, per-manga settings, download ahead, downloads, pinned source and library filter.
    private func fill(_ store: ConversionStore) throws {
        let context = store.container.newBackgroundContext()
        try context.performAndWait {
            let category = store.insert("Category", ["title": "Leyendo", "sort": Int16(0), "group": false], in: context)
            for (mangaId, sourceId) in [("101", parent), ("102", parent), ("103", parent), ("104", parent), ("1", "multi.otra")] {
                let manga = store.insert("Manga", [
                    "sourceId": sourceId, "id": mangaId, "title": "Manga \(mangaId)", "cover": "https://s/\(mangaId).png",
                    "author": "Autor", "viewer": Int16(2), "status": Int16(1), "nsfw": Int16(0), "neverUpdate": false,
                    "chapterFlags": Int16(0), "editedKeys": Int32(0)
                ], in: context)
                let library = store.insert("LibraryManga", [
                    "dateAdded": date1, "lastOpened": date2, "lastRead": date2, "lastUpdated": date1,
                    "lastUpdatedChapters": date1, "manga": manga
                ], in: context)
                library.setValue(Set([category]), forKey: "categories")
                var chapters: [NSManagedObject] = []
                for number in 1...3 {
                    chapters.append(store.insert("Chapter", [
                        "sourceId": sourceId, "mangaId": mangaId, "id": "\(mangaId)0\(number)",
                        "title": "Cap \(number)", "chapter": NSNumber(value: Float(number)), "sourceOrder": Int16(3 - number),
                        "dateUploaded": date1, "manga": manga, "locked": false, "lang": "es"
                    ], in: context))
                }
                let read = store.insert("History", [
                    "sourceId": sourceId, "mangaId": mangaId, "chapterId": "\(mangaId)01", "completed": true,
                    "progress": Int16(0), "dateRead": date1, "chapter": chapters[0]
                ], in: context)
                let unfinished = store.insert("History", [
                    "sourceId": sourceId, "mangaId": mangaId, "chapterId": "\(mangaId)02", "completed": false,
                    "progress": Int16(5), "total": Int16(90), "scrollPosition": 0.25, "dateRead": date2, "chapter": chapters[1]
                ], in: context)
                store.insert("ReadingSession", [
                    "startDate": date1.addingTimeInterval(Double(Int(mangaId) ?? 0)), "endDate": date2, "pagesRead": Int16(12), "history": unfinished
                ], in: context)
                _ = read
                store.insert("MangaUpdate", [
                    "sourceId": sourceId, "mangaId": mangaId, "chapterId": "\(mangaId)03", "date": date2, "viewed": false, "chapter": chapters[2]
                ], in: context)
                store.insert("Track", [
                    "id": "\(sourceId)|\(mangaId)", "trackerId": "suwayomi", "sourceId": sourceId, "mangaId": mangaId, "title": "Manga \(mangaId)",
                    "chapterOffset": Int16(0)
                ], in: context)
                store.insert("Vocab", [
                    "sourceId": sourceId, "mangaId": mangaId, "chapterId": "\(mangaId)01", "word": "palabra", "createdDate": date1, "page": Int16(1)
                ], in: context)
            }
            try context.save()
        }
        let defaults = store.defaults
        for (mangaId, sourceId) in [("101", parent), ("102", parent), ("103", parent), ("104", parent), ("1", "multi.otra")] {
            defaults.set("webtoon", forKey: "Reader.readingMode.\(sourceId).\(mangaId)")
            defaults.set(true, forKey: "Reader.pagedPageOffset.\(sourceId).\(mangaId)")
            defaults.set(2, forKey: "Manga.chapterDisplayMode.\(sourceId).\(mangaId)")
            defaults.set(3, forKey: "DownloadAhead.\(sourceId).\(mangaId)")
        }
        defaults.set("https://suwayomi.example:4567", forKey: "\(parent).server") // the parent's own: stays
        defaults.set([parent, "multi.otra"], forKey: "Browse.pinnedList")
        defaults.set(try JSONEncoder().encode([LibraryFilter(type: .source, value: parent, exclude: false)]), forKey: "Library.filters")
        let queue: [String: [[String: Any]]] = [parent: [[
            "chapterIdentifier": ["sourceKey": parent, "mangaKey": "101", "chapterKey": "10103"],
            "manga": ["sourceKey": parent, "key": "101", "title": "Manga 101"],
            "status": 1
        ]]]
        defaults.set(try JSONSerialization.data(withJSONObject: queue), forKey: "Data.downloadQueueState")
        defaults.set(try JSONEncoder().encode([ChapterIdentifier(sourceKey: parent, mangaKey: "102", chapterKey: "10201")]), forKey: "Data.chaptersToBeDeleted")
        let pageState: [String: Any] = ["pendingPageUpdates": [[
            "trackerId": "suwayomi", "trackId": "\(parent)|103",
            "chapterId": ["sourceKey": parent, "mangaKey": "103", "chapterKey": "10302"],
            "progress": ["completed": false, "page": 5, "total": 90], "failCount": 0
        ]]]
        defaults.set(try JSONSerialization.data(withJSONObject: pageState), forKey: "Tracker.pageTrackingState")
        for mangaId in ["101", "104"] {
            let folder = store.downloads.appendingPathComponent(parent).appendingPathComponent(mangaId)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("cbz \(mangaId)".utf8).write(to: folder.appendingPathComponent("\(mangaId)03.cbz"))
        }
    }

    private func resolveAll(_ map: [String: String]) -> @Sendable (String, [String]) async throws -> [String: String] {
        { _, ids in map.filter { ids.contains($0.key) } }
    }

    // MARK: T1

    @Test func everythingStaysButTheKey() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        try fill(store)
        let expected = expectedKey
        let parent = parent
        // what the data must be after: the same, with the source key of each converted manga changed
        let before = store.snapshot { _ in "·" }
        let backups = BackupCounter()
        let report = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(resolve: resolveAll(serverMap), children: children, backup: { backups.asked(); return true })
        )
        #expect(report.outcome == .done)
        #expect(report.converted == 3)
        #expect(report.pending == 1)
        #expect(report.failed == 0)
        #expect(report.pendingIds == [parent: ["104"]])
        #expect(backups.count == 1)

        // field by field, every entity: equal but the key
        #expect(store.snapshot { _ in "·" } == before)
        let rowsPerManga = ["Manga": 1, "Chapter": 3, "History": 2, "MangaUpdate": 1, "Track": 1, "Vocab": 1]
        for (mangaId, child) in expected {
            for entity in SuwayomiSourceConversion.entities {
                #expect(countRows(store, entity, sourceId: child, mangaId: mangaId) == rowsPerManga[entity], "\(entity) \(mangaId)")
                #expect(countRows(store, entity, sourceId: parent, mangaId: mangaId) == 0, "\(entity) \(mangaId)")
            }
        }
        // unknown to the server: intact under the parent; another source: intact
        for entity in SuwayomiSourceConversion.entities {
            #expect(countRows(store, entity, sourceId: parent, mangaId: "104") >= 1)
            #expect(countRows(store, entity, sourceId: "multi.otra", mangaId: "1") >= 1)
        }
        // the unfinished chapter: page, total, position, date; the track id is kept (`<parent>|<id>`)
        let unfinished = try #require(history(store, sourceId: childA, chapterId: "10102"))
        #expect(unfinished.progress == 5 && unfinished.total == 90 && unfinished.completed == false)
        #expect(unfinished.dateRead == date2)
        #expect(trackIds(store, sourceId: childA) == ["\(parent)|101", "\(parent)|102"])

        // per-manga settings moved; the parent's own and the others' stay
        let defaults = store.defaults
        for (mangaId, child) in expected {
            #expect(defaults.string(forKey: "Reader.readingMode.\(child).\(mangaId)") == "webtoon")
            #expect(defaults.bool(forKey: "Reader.pagedPageOffset.\(child).\(mangaId)"))
            #expect(defaults.integer(forKey: "Manga.chapterDisplayMode.\(child).\(mangaId)") == 2)
            #expect(defaults.integer(forKey: "DownloadAhead.\(child).\(mangaId)") == 3)
            #expect(defaults.object(forKey: "Reader.readingMode.\(parent).\(mangaId)") == nil)
        }
        #expect(defaults.string(forKey: "Reader.readingMode.\(parent).104") == "webtoon")
        #expect(defaults.string(forKey: "Reader.readingMode.multi.otra.1") == "webtoon")
        #expect(defaults.string(forKey: "\(parent).server") != nil)

        // downloads moved (not copied); the unknown one stays
        let moved = store.downloads.appendingPathComponent(childA).appendingPathComponent("101").appendingPathComponent("10103.cbz")
        #expect((try? String(contentsOf: moved, encoding: .utf8)) == "cbz 101")
        #expect(!FileManager.default.fileExists(atPath: store.downloads.appendingPathComponent(parent).appendingPathComponent("101").path))
        #expect(FileManager.default.fileExists(atPath: store.downloads.appendingPathComponent(parent).appendingPathComponent("104/10403.cbz").path))

        // settings with source keys
        #expect(defaults.stringArray(forKey: "Browse.pinnedList") == ["multi.otra"])
        let filtersData = try #require(defaults.data(forKey: "Library.filters"))
        let filters = try JSONDecoder().decode([LibraryFilter].self, from: filtersData)
        #expect(Set(filters.compactMap(\.value)) == [parent, childA, childB]) // the parent still has 104
        #expect(filters.allSatisfy { $0.type == .source && !$0.exclude })
        let queueData = try #require(defaults.data(forKey: "Data.downloadQueueState"))
        let queue = try #require(try JSONSerialization.jsonObject(with: queueData) as? [String: [[String: Any]]])
        #expect(Array(queue.keys) == [childA])
        let download = try #require(queue[childA]?.first)
        #expect((download["chapterIdentifier"] as? [String: Any])?["sourceKey"] as? String == childA)
        #expect((download["manga"] as? [String: Any])?["sourceKey"] as? String == childA)
        let toDeleteData = try #require(defaults.data(forKey: "Data.chaptersToBeDeleted"))
        let toDelete = try JSONDecoder().decode([ChapterIdentifier].self, from: toDeleteData)
        #expect(toDelete == [ChapterIdentifier(sourceKey: childA, mangaKey: "102", chapterKey: "10201")])
        // a pending page update: its chapter goes to the new source, the track id stays
        let pageData = try #require(defaults.data(forKey: "Tracker.pageTrackingState"))
        let pending = try #require((try JSONSerialization.jsonObject(with: pageData) as? [String: Any])?["pendingPageUpdates"] as? [[String: Any]])
        #expect((pending.first?["chapterId"] as? [String: Any])?["sourceKey"] as? String == childB)
        #expect(pending.first?["trackId"] as? String == "\(parent)|103")
        _ = before
    }

    // MARK: T2

    @Test func convertingTwiceIsTheSame() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        try fill(store)
        let backups = BackupCounter()
        let env = store.environment(resolve: resolveAll(serverMap), children: children, backup: { backups.asked(); return true })
        _ = await SuwayomiSourceConversion.run(parentKeys: [parent], environment: env)
        let once = store.snapshot()
        let settings = store.defaults.persistentDomain(forName: store.domain).map { NSDictionary(dictionary: $0) }
        let again = await SuwayomiSourceConversion.run(parentKeys: [parent], environment: env)
        #expect(again.converted == 0)
        #expect(again.pending == 1) // 104, still unknown
        #expect(backups.count == 1) // nothing to convert: no second backup
        #expect(store.snapshot() == once)
        #expect(store.defaults.persistentDomain(forName: store.domain).map { NSDictionary(dictionary: $0) } == settings)
    }

    @Test func oldRowsComingBackAreConvertedAndMergedKeepingTheMostComplete() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        try fill(store)
        let env = store.environment(resolve: resolveAll(serverMap), children: children)
        _ = await SuwayomiSourceConversion.run(parentKeys: [parent], environment: env)
        // an old backup (or iCloud) brings rows of 101 under the parent again: the read chapter older,
        // the unfinished one further on, and a chapter read only there
        let context = store.container.newBackgroundContext()
        let parent = parent
        try context.performAndWait {
            let manga = store.insert("Manga", [
                "sourceId": parent, "id": "101", "title": "Manga 101", "neverUpdate": false, "chapterFlags": Int16(0),
                "editedKeys": Int32(0), "nsfw": Int16(0), "status": Int16(0), "viewer": Int16(0)
            ], in: context)
            _ = manga
            store.insert("History", ["sourceId": parent, "mangaId": "101", "chapterId": "10101", "completed": false, "progress": Int16(3), "dateRead": date1], in: context)
            store.insert("History", ["sourceId": parent, "mangaId": "101", "chapterId": "10102", "completed": false, "progress": Int16(40), "total": Int16(90), "dateRead": date2.addingTimeInterval(60)], in: context)
            store.insert("History", ["sourceId": parent, "mangaId": "101", "chapterId": "10103", "completed": true, "progress": Int16(0), "dateRead": date2], in: context)
            store.insert("Track", ["id": "\(parent)|101", "trackerId": "suwayomi", "sourceId": parent, "mangaId": "101", "chapterOffset": Int16(0)], in: context)
            try context.save()
        }
        let report = await SuwayomiSourceConversion.run(parentKeys: [parent], environment: env)
        #expect(report.converted == 1)
        #expect(report.merged == 4) // manga, 2 histories, track
        for entity in SuwayomiSourceConversion.entities {
            #expect(countRows(store, entity, sourceId: parent, mangaId: "101") == 0)
        }
        #expect(countRows(store, "Manga", sourceId: childA, mangaId: "101") == 1)
        #expect(countRows(store, "Track", sourceId: childA, mangaId: "101") == 1)
        #expect(countRows(store, "History", sourceId: childA, mangaId: "101") == 3)
        #expect(history(store, sourceId: childA, chapterId: "10101")?.completed == true) // completed wins
        #expect(history(store, sourceId: childA, chapterId: "10102")?.progress == 40) // further on wins
        #expect(history(store, sourceId: childA, chapterId: "10103")?.completed == true) // only there: kept
        // the library entry and its category are still there
        #expect(store.snapshot()["LibraryManga"]?.filter { $0.contains("Manga(\(childA),101)") }.count == 1)
    }

    // MARK: T3

    @Test func aServerThatDoesntAnswerOrABackupThatFailsWritesNothing() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        try fill(store)
        let before = store.snapshot()
        let settings = store.defaults.persistentDomain(forName: store.domain).map { NSDictionary(dictionary: $0) }
        let backups = BackupCounter()
        let down = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(resolve: { _, _ in throw SourceError.networkError }, children: children, backup: { backups.asked(); return true })
        )
        #expect(down.outcome == .serverUnavailable)
        #expect(backups.count == 0)
        let noBackup = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(resolve: resolveAll(serverMap), children: children, backup: { false })
        )
        #expect(noBackup.outcome == .backupFailed)
        #expect(store.snapshot() == before)
        #expect(store.defaults.persistentDomain(forName: store.domain).map { NSDictionary(dictionary: $0) } == settings)
        #expect(FileManager.default.fileExists(atPath: store.downloads.appendingPathComponent(parent).appendingPathComponent("101/10103.cbz").path))
    }

    @Test func aServerThatAnswersOnlyPartlyConvertsOnlyWholeManga() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        try fill(store)
        // only 101 known; 103's source is not on the server (no child for it)
        let partial = ["101": sourceA, "103": "999"]
        let report = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(resolve: resolveAll(partial), children: children)
        )
        #expect(report.converted == 1)
        #expect(report.pending == 3)
        for entity in SuwayomiSourceConversion.entities {
            #expect(countRows(store, entity, sourceId: parent, mangaId: "101") == 0, "\(entity)")
            #expect(countRows(store, entity, sourceId: childA, mangaId: "101") >= 1, "\(entity)")
            for pending in ["102", "103", "104"] {
                #expect(countRows(store, entity, sourceId: parent, mangaId: pending) >= 1, "\(entity) \(pending)")
            }
        }
        #expect(store.defaults.string(forKey: "Reader.readingMode.\(parent).102") == "webtoon")
    }

    @Test func perMangaSettingKeysAreRecognised() {
        func parts(_ key: String) -> String? {
            SuwayomiSourceConversion.perMangaKey(key, parent: "suwayomi.suwa").map { "\($0.prefix)|\($0.mangaId)" }
        }
        #expect(parts("Reader.readingMode.suwayomi.suwa.101") == "Reader.readingMode|101")
        #expect(parts("DownloadAhead.suwayomi.suwa.101") == "DownloadAhead|101")
        #expect(SuwayomiSourceConversion.perMangaKey("suwayomi.suwa.server", parent: "suwayomi.suwa") == nil)
        #expect(SuwayomiSourceConversion.perMangaKey("suwayomi.suwa.123.filters", parent: "suwayomi.suwa") == nil)
        #expect(SuwayomiSourceConversion.perMangaKey("Reader.readingMode.suwayomi.suwa.1596411039134168890.101", parent: "suwayomi.suwa") == nil)
        #expect(SuwayomiSourceConversion.perMangaKey("Reader.readingMode.multi.otra.1", parent: "suwayomi.suwa") == nil)
    }

    // MARK: Helpers

    private func countRows(_ store: ConversionStore, _ entity: String, sourceId: String, mangaId: String) -> Int {
        let context = store.container.newBackgroundContext()
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "sourceId == %@ AND \(entity == "Manga" ? "id" : "mangaId") == %@", sourceId, mangaId)
            return (try? context.count(for: request)) ?? 0
        }
    }

    private struct HistoryValues {
        let completed: Bool
        let progress: Int
        let total: Int
        let dateRead: Date?
    }

    private func history(_ store: ConversionStore, sourceId: String, chapterId: String) -> HistoryValues? {
        let context = store.container.newBackgroundContext()
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "History")
            request.predicate = NSPredicate(format: "sourceId == %@ AND chapterId == %@", sourceId, chapterId)
            guard let object = try? context.fetch(request).first else { return nil }
            return .init(
                completed: object.value(forKey: "completed") as? Bool ?? false,
                progress: Int(object.value(forKey: "progress") as? Int16 ?? 0),
                total: Int(object.value(forKey: "total") as? Int16 ?? 0),
                dateRead: object.value(forKey: "dateRead") as? Date
            )
        }
    }

    private func trackIds(_ store: ConversionStore, sourceId: String) -> [String] {
        let context = store.container.newBackgroundContext()
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Track")
            request.predicate = NSPredicate(format: "sourceId == %@", sourceId)
            return ((try? context.fetch(request)) ?? []).compactMap { $0.value(forKey: "id") as? String }.sorted()
        }
    }
}
