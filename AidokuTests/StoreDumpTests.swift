//
//  StoreDumpTests.swift
//  AidokuTests
//
//  SUWA-13 F3: the safety net before moving the data layer. T-R (real copies, SUWA13_COPIA = a folder with
//  <device>/Library/Application Support/{Aidoku,Local}.sqlite*, skipped without it), T-S (a synthetic store with
//  extreme values, always), T-M (sqlite metadata tables). Copies are never opened in place, and nothing readable
//  of them is written (see StoreDump).
//

import CoreData
import Foundation
import SQLite3
import Testing

@testable import Aidoku

private let copyFolder = ProcessInfo.processInfo.environment["SUWA13_COPIA"].map { URL(fileURLWithPath: $0) }

/// Checks that a dump is complete: every entity of the model is in it with the rows its sqlite table has
/// (counted with sqlite, not with Core Data), and the metadata tables are listed.
func expectComplete(_ dump: StoreDump, stores folder: URL) throws {
    let names = Set(StoreDump.model.entities.compactMap(\.name))
    #expect(Set(dump.entities.keys) == names)
    for entity in StoreDump.model.entities {
        let name = entity.name!
        let file = name == "Source" ? "Local.sqlite" : "Aidoku.sqlite"
        let rows = try StoreDump.sqliteCount(in: folder, file: file, table: "Z" + name.uppercased())
        #expect(dump.entities[name]?.count == rows, "\(name)")
    }
}

func expectMetadataListed(_ dump: StoreDump) {
    for file in StoreDump.storeFiles {
        for table in ["Z_METADATA", "Z_MODELCACHE", "Z_PRIMARYKEY"] {
            #expect(dump.tableNames[file]?.contains(table) == true, "\(file)/\(table)")
            #expect(dump.metadata["\(file)/\(table)"] != nil, "\(file)/\(table)")
        }
    }
    #expect(dump.tableNames["Aidoku.sqlite"]?.contains("ATRANSACTION") == true)
    #expect(dump.metadata["Aidoku.sqlite/ATRANSACTION"] != nil)
}

@Suite(.serialized) struct StoreDumpRealDataTests {
    private func stores(_ device: String) throws -> URL {
        let folder = try #require(copyFolder).appendingPathComponent(device).appendingPathComponent("Library/Application Support")
        try #require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Aidoku.sqlite").path))
        return folder
    }

    /// (a) The dump is deterministic: two dumps of the same copy, each opened anew, are the same.
    @Test(.enabled(if: copyFolder != nil), arguments: ["iphone", "ipad"])
    func dumpingTheSameCopyTwiceGivesTheSame(device: String) throws {
        let folder = try stores(device)
        let first = try StoreDump.dumpCopy(of: folder)
        let second = try StoreDump.dumpCopy(of: folder)
        try expectComplete(first, stores: folder)
        expectMetadataListed(first)
        #expect(first.differences(to: second) == [])
        #expect(first == second)
        try first.write(label: "\(device)-original")
    }

    /// (b) Opening the copy with the app's stack (its model, lightweight migration on, no CloudKit) and saving
    /// without changes changes nothing: same entities, and the metadata tables that must stay put stay put.
    @Test(.enabled(if: copyFolder != nil), arguments: ["iphone", "ipad"])
    func openingWithTheAppStackAndSavingChangesNothing(device: String) throws {
        let folder = try stores(device)
        let original = try StoreDump.dumpCopy(of: folder)
        let directory = try StoreDump.copyStores(from: folder)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try StoreDump.appContainer(directory: directory)
        let context = container.viewContext
        try context.performAndWait {
            #expect(!context.hasChanges)
            try context.save()
        }
        StoreDump.close(container)

        let after = try StoreDump.dumpCopy(of: directory)
        try expectComplete(after, stores: directory)
        let changed = original.differences(to: after).filter { $0.hasPrefix("tabla ") }
        try writeChanges(changed, label: "\(device)-cambios-al-abrir")
        #expect(original.differences(to: after, metadataTables: StoreDump.metadataThatStays(in: original)) == [])
        #expect(after.entities == original.entities)
        try after.write(label: "\(device)-abierta-con-la-app")
    }

    /// (c) Creating a History and a Category (linked to a chapter without history and to a library entry),
    /// saving, deleting them and saving again leaves every entity as it was.
    @Test(.enabled(if: copyFolder != nil), arguments: ["iphone", "ipad"])
    func creatingAndDeletingLeavesNoTrace(device: String) throws {
        let folder = try stores(device)
        let original = try StoreDump.dumpCopy(of: folder)
        let directory = try StoreDump.copyStores(from: folder)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try StoreDump.appContainer(directory: directory)
        let context = container.viewContext
        try context.performAndWait {
            let history = NSEntityDescription.insertNewObject(forEntityName: "History", into: context)
            history.setValue("suwa13.test", forKey: "sourceId")
            history.setValue("manga", forKey: "mangaId")
            history.setValue("chapter-\(UUID().uuidString)", forKey: "chapterId")
            history.setValue(Date(), forKey: "dateRead")
            let free = NSFetchRequest<NSManagedObject>(entityName: "Chapter")
            free.predicate = NSPredicate(format: "history == nil")
            free.fetchLimit = 1
            if let chapter = try context.fetch(free).first {
                history.setValue(chapter, forKey: "chapter")
            }
            let category = NSEntityDescription.insertNewObject(forEntityName: "Category", into: context)
            category.setValue("suwa13-\(UUID().uuidString)", forKey: "title")
            let library = NSFetchRequest<NSManagedObject>(entityName: "LibraryManga")
            library.fetchLimit = 1
            if let entry = try context.fetch(library).first {
                category.mutableSetValue(forKey: "libraryObjects").add(entry)
            }
            try context.save()
            context.delete(history)
            context.delete(category)
            try context.save()
        }
        StoreDump.close(container)

        let after = try StoreDump.dumpCopy(of: directory)
        try expectComplete(after, stores: directory)
        #expect(original.differences(to: after, metadataTables: []) == [])
        #expect(after.entities == original.entities)
    }

    private func writeChanges(_ lines: [String], label: String) throws {
        guard let out = ProcessInfo.processInfo.environment["SUWA13_OUT"] else { return }
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: URL(fileURLWithPath: out).appendingPathComponent("\(label).txt"), atomically: true, encoding: .utf8
        )
    }
}

/// T-S: every entity with extreme values, in a temporary store (no copies needed).
@Suite(.serialized) struct StoreDumpSyntheticTests {
    static let expectedCounts = [
        "Category": 3, "Chapter": 302, "History": 3, "LibraryManga": 302, "LocalFileInfo": 2, "Manga": 303,
        "MangaUpdate": 2, "ReadingSession": 301, "Source": 2, "Track": 2, "Vocab": 2
    ]
    private static let distantPast = Date.distantPast
    private static let bytes = Data((0...255).map(UInt8.init) + [0, 0, 255])

    /// The stack used here is the app's: same container class and store descriptions.
    @Test func theCopiedStackIsTheAppStack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("suwa13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try StoreDump.appContainer(directory: directory)
        defer { StoreDump.close(container) }
        let app = CoreDataManager.shared.container
        #expect(type(of: container) == type(of: app))
        #expect(container.persistentStoreDescriptions.count == app.persistentStoreDescriptions.count)
        for (mine, theirs) in zip(container.persistentStoreDescriptions, app.persistentStoreDescriptions) {
            #expect(mine.configuration == theirs.configuration)
            #expect(mine.type == theirs.type)
            #expect(mine.url?.lastPathComponent == theirs.url?.lastPathComponent)
            #expect(mine.shouldMigrateStoreAutomatically == theirs.shouldMigrateStoreAutomatically)
            #expect(mine.shouldInferMappingModelAutomatically == theirs.shouldInferMappingModelAutomatically)
            #expect(mine.isReadOnly == theirs.isReadOnly)
            #expect(NSDictionary(dictionary: mine.options) == NSDictionary(dictionary: theirs.options))
        }
        #expect(container.viewContext.automaticallyMergesChangesFromParent == app.viewContext.automaticallyMergesChangesFromParent)
        #expect((container.viewContext.mergePolicy as? NSMergePolicy)?.mergeType == (app.viewContext.mergePolicy as? NSMergePolicy)?.mergeType)
    }

    @Test func aReopenedStoreDumpsTheSame() throws {
        let directory = try Self.extremeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var container = try StoreDump.appContainer(directory: directory)
        let first = try StoreDump.make(context: container.newBackgroundContext())
        StoreDump.close(container)
        container = try StoreDump.appContainer(directory: directory)
        let second = try StoreDump.make(context: container.newBackgroundContext())
        StoreDump.close(container)

        #expect(first.entities.mapValues(\.count) == Self.expectedCounts)
        #expect(first.entities.filter { $0.value.duplicateKeys > 0 }.mapValues(\.duplicateKeys) == ["Chapter": 1])
        // every row of each kind differs from the others (nil, 0, false, -1, "" and 0.0 are told apart)
        for (name, entity) in first.entities {
            #expect(Set(entity.lines).count == entity.count, "\(name)")
        }
        #expect(first.differences(to: second) == [])
        #expect(first == second)
        let fromFiles = try StoreDump.dumpCopy(of: directory)
        #expect(fromFiles.entities == first.entities)
        expectMetadataListed(fromFiles)
    }

    /// C1: a transformable is dumped as the bytes in its column, not re-archived: the same [String] archived
    /// another way (an XML keyed archive, which Core Data decodes the same) dumps differently.
    @Test func aTransformableArchivedAnotherWayDumpsDifferently() throws {
        let directory = try Self.extremeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try StoreDump.dumpCopy(of: directory)

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.outputFormat = .xml
        archiver.encode(["uno"] as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let store = directory.appendingPathComponent("Aidoku.sqlite").path
        let stored = try sqliteBlob(store, "SELECT ZTAGS FROM ZMANGA WHERE ZSOURCEID = 'test' AND ZID = 'm2'")
        #expect(stored != archiver.encodedData)
        try sqliteExec(store, "UPDATE ZMANGA SET ZTAGS = ?1 WHERE ZSOURCEID = 'test' AND ZID = 'm2'", [.blob(archiver.encodedData)])

        // Core Data reads the same value
        let container = try StoreDump.appContainer(directory: directory)
        let context = container.newBackgroundContext()
        let tags = try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Manga")
            request.predicate = NSPredicate(format: "sourceId == %@ AND id == %@", "test", "m2")
            return try context.fetch(request).first?.value(forKey: "tags") as? [String]
        }
        StoreDump.close(container)
        #expect(tags == ["uno"])

        let after = try StoreDump.dumpCopy(of: directory)
        #expect(after.entities["Manga"] != before.entities["Manga"])
        #expect(before.differences(to: after).contains { $0.hasPrefix("Manga:") })
    }

    /// C1: a Float is dumped also as the REAL in its column: a REAL written with more precision than a Float holds
    /// (Core Data reads the same Float) dumps differently.
    @Test func aRealWrittenWithAnotherPrecisionDumpsDifferently() throws {
        let directory = try Self.extremeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try StoreDump.dumpCopy(of: directory)
        let store = directory.appendingPathComponent("Aidoku.sqlite").path
        try sqliteExec(store, "UPDATE ZCHAPTER SET ZCHAPTER = ?1 WHERE ZMANGAID = 'm2' AND ZID = 'c10'", [.double(9.000000001)])

        let container = try StoreDump.appContainer(directory: directory)
        let context = container.newBackgroundContext()
        let number = try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Chapter")
            request.predicate = NSPredicate(format: "mangaId == %@ AND id == %@", "m2", "c10")
            return try context.fetch(request).first?.value(forKey: "chapter") as? NSNumber
        }
        StoreDump.close(container)
        #expect(number?.floatValue == 9)

        let after = try StoreDump.dumpCopy(of: directory)
        #expect(after.entities["Chapter"] != before.entities["Chapter"])
    }

    /// C2: Z_METADATA is compared key by key. Only NSPersistenceFrameworkVersion may change (the framework that
    /// last saved the store); NSStoreUUID or a new key may not.
    @Test func theStoreMetadataIsComparedKeyByKey() throws {
        let directory = try Self.extremeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Self.metadataDump(directory)
        let otherFramework = try Self.metadataDump(directory) { $0["NSPersistenceFrameworkVersion"] = "1" }
        let otherUUID = try Self.metadataDump(directory) { $0["NSStoreUUID"] = UUID().uuidString }
        let newKey = try Self.metadataDump(directory) { $0["SUWA13Nueva"] = "x" }
        let otherModel = try Self.metadataDump(directory) { $0["NSStoreModelVersionIdentifiers"] = ["otro"] }
        #expect(Self.compare(original, otherFramework) == [])
        #expect(Self.compare(original, otherUUID).count == 1)
        #expect(Self.compare(original, newKey).count == 1)
        #expect(Self.compare(original, otherModel).count == 1)
    }

    /// The comparison of copies that test (b) uses.
    static func compare(_ before: StoreDump, _ after: StoreDump) -> [String] {
        before.differences(to: after, metadataTables: StoreDump.metadataThatStays(in: before))
    }

    /// The metadata tables of a copy of `directory` whose Aidoku.sqlite Z_METADATA plist went through `change`.
    static func metadataDump(_ directory: URL, change: ((inout [String: Any]) -> Void)? = nil) throws -> StoreDump {
        let copy = try StoreDump.copyStores(from: directory)
        defer { try? FileManager.default.removeItem(at: copy) }
        if let change {
            let store = copy.appendingPathComponent("Aidoku.sqlite").path
            let data = try sqliteBlob(store, "SELECT Z_PLIST FROM Z_METADATA")
            var plist = try #require(try PropertyListSerialization.propertyList(from: data, options: 0, format: nil) as? [String: Any])
            change(&plist)
            let changed = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try sqliteExec(store, "UPDATE Z_METADATA SET Z_PLIST = ?1", [.blob(changed)])
        }
        var dump = StoreDump()
        dump.metadata = try StoreDump.tables(in: copy).metadata
        return dump
    }

    /// Deleting follows the model's rules:
    /// - a Manga: its LibraryManga goes (Cascade); its chapters, their updates and histories, its LocalFileInfo
    ///   and the categories stay, only without it (Nullify);
    /// - a Chapter: its MangaUpdate goes (Cascade); its History and its LocalFileInfo stay, without it (Nullify);
    /// - a History: its ReadingSessions go (Cascade); its chapter stays (Nullify).
    @Test func deletingFollowsTheModelRules() throws {
        let directory = try Self.extremeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try StoreDump.appContainer(directory: directory)
        defer { StoreDump.close(container) }
        let context = container.newBackgroundContext()
        let before = try StoreDump.make(context: context)
        #expect(before.entities.mapValues(\.count) == Self.expectedCounts)
        func rows(_ dump: StoreDump, _ name: String) -> Int { dump.entities[name]?.count ?? -1 }

        func one(_ entity: String, _ format: String, _ args: CVarArg...) throws -> NSManagedObject {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: format, argumentArray: args)
            return try #require(try context.fetch(request).first)
        }
        func count(_ entity: String, _ format: String, _ args: CVarArg...) throws -> Int {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: format, argumentArray: args)
            return try context.count(for: request)
        }

        // a Manga with library entry, 300 chapters (one with an update, three with histories) and a file
        try context.performAndWait {
            context.delete(try one("Manga", "sourceId == %@ AND id == %@", "test", "m2"))
            try context.save()
        }
        var after = try StoreDump.make(context: context)
        var counts = after.entities.mapValues(\.count)
        #expect(counts["Manga"] == rows(before, "Manga") - 1)
        #expect(counts["LibraryManga"] == rows(before, "LibraryManga") - 1) // Cascade
        for name in ["Chapter", "MangaUpdate", "History", "ReadingSession", "Category", "LocalFileInfo", "Track"] {
            #expect(counts[name] == rows(before, name), "\(name) stays") // Nullify
        }
        let orphanChapters = try context.performAndWait { try count("Chapter", "mangaId == %@ AND manga == nil", "m2") }
        let orphanFiles = try context.performAndWait { try count("LocalFileInfo", "path == %@ AND manga == nil", "a/ñ 🙂.cbz") }
        let inUno = try context.performAndWait { try one("Category", "title == %@", "uno").mutableSetValue(forKey: "libraryObjects").count }
        #expect(orphanChapters == 300)
        #expect(orphanFiles == 1)
        #expect(inUno == 0)

        // a Chapter with an update, a history and a file
        try context.performAndWait {
            context.delete(try one("Chapter", "mangaId == %@ AND id == %@", "m2", "c1"))
            try context.save()
        }
        let afterManga = after
        after = try StoreDump.make(context: context)
        counts = after.entities.mapValues(\.count)
        #expect(counts["Chapter"] == rows(afterManga, "Chapter") - 1)
        #expect(counts["MangaUpdate"] == rows(afterManga, "MangaUpdate") - 1) // Cascade
        #expect(counts["History"] == rows(afterManga, "History")) // Nullify
        let orphanHistories = try context.performAndWait { try count("History", "chapterId == %@ AND chapter == nil", "c1") }
        #expect(orphanHistories == 1)

        // a History with 300 sessions
        try context.performAndWait {
            context.delete(try one("History", "chapterId == %@", "c0"))
            try context.save()
        }
        let afterChapter = after
        after = try StoreDump.make(context: context)
        counts = after.entities.mapValues(\.count)
        #expect(counts["History"] == rows(afterChapter, "History") - 1)
        #expect(counts["ReadingSession"] == rows(afterChapter, "ReadingSession") - 300) // Cascade
        #expect(counts["Chapter"] == rows(afterChapter, "Chapter")) // Nullify
        let historyOfC0 = try context.performAndWait { try one("Chapter", "mangaId == %@ AND id == %@", "m2", "c0").value(forKey: "history") }
        #expect(historyOfC0 == nil)
    }

    // MARK: - The store

    /// A temporary folder with the app's stores holding every entity with extreme values.
    static func extremeStore() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("suwa13-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try StoreDump.appContainer(directory: directory)
        defer { StoreDump.close(container) }
        let context = container.newBackgroundContext()
        try context.performAndWait {
            func new(_ entity: String, _ values: [String: Any?]) -> NSManagedObject {
                let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
                for (key, value) in values {
                    object.setValue(value ?? nil, forKey: key) // nil on purpose: over the defaults
                }
                return object
            }
            let optionalsOfManga = ["artist", "author", "cover", "desc", "langFilter", "nextUpdateTime", "scanlatorFilter", "tags", "url"]

            // m0: every optional nil, numbers 0, no chapters, no library entry
            _ = new("Manga", Dictionary(uniqueKeysWithValues: optionalsOfManga.map { ($0, nil as Any?) })
                .merging(["sourceId": "test", "id": "m0", "title": ""]) { $1 })
            // m1: optionals empty (not nil), the largest numbers, unicode, one chapter
            let m1 = new("Manga", [
                "sourceId": "test", "id": "m1", "title": "ñ漢字🙂‍↔️e\u{301}", "artist": "", "author": "", "cover": "",
                "desc": "coma, \"comillas\"\nsalto", "langFilter": "", "url": "https://example.test/a?b=c,d", "tags": [String](),
                "scanlatorFilter": [String](), "chapterFlags": Int16.max, "editedKeys": Int32.max, "nsfw": Int16.min,
                "viewer": Int16.max, "neverUpdate": true, "nextUpdateTime": distantPast, "status": Int16.max
            ])
            // m2: one tag, 50 scanlators, the smallest numbers, 300 chapters, a library entry
            let m2 = new("Manga", [
                "sourceId": "test", "id": "m2", "title": "m2", "tags": ["uno"], "scanlatorFilter": (0..<50).map { "scan \($0)" },
                "editedKeys": Int32.min, "chapterFlags": Int16.min, "status": -1, "viewer": -1
            ])

            let c1of1 = new("Chapter", [
                "sourceId": "test", "mangaId": "m1", "id": "c", "title": "🙂", "chapter": Float(0), "volume": Float(0),
                "scanlator": "", "lang": "", "locked": true, "dateUploaded": distantPast, "sourceOrder": Int16.max
            ])
            c1of1.setValue(m1, forKey: "manga")
            // the same natural key again, not linked: both rows are kept
            _ = new("Chapter", ["sourceId": "test", "mangaId": "m1", "id": "c", "title": "otra", "chapter": nil, "volume": nil])
            var chapters: [NSManagedObject] = []
            for index in 0..<300 {
                let chapter = new("Chapter", [
                    "sourceId": "test", "mangaId": "m2", "id": "c\(index)", "sourceOrder": Int16(index - 150),
                    "chapter": index == 0 ? nil : Float(index == 2 ? -1 : index - 1),
                    "volume": index == 0 ? nil : Float(index == 1 ? 0 : -1),
                    "scanlator": index == 3 ? nil : "s", "title": index == 4 ? nil : "t\(index)",
                    "dateUploaded": index == 5 ? distantPast : nil, "url": index == 6 ? "" : nil, "thumbnail": index == 7 ? "" : nil
                ])
                chapter.setValue(m2, forKey: "manga")
                chapters.append(chapter)
            }

            // histories: completed nil / false / true, scrollPosition nil / 0.0 / -1.5, total nil / 0 / max; 300, 1, 0 sessions
            let histories = [
                new("History", ["sourceId": "test", "mangaId": "m2", "chapterId": "c0", "completed": nil, "scrollPosition": nil,
                                "total": nil, "progress": Int16(0), "dateRead": Date(timeIntervalSinceReferenceDate: 0.000001)]),
                new("History", ["sourceId": "test", "mangaId": "m2", "chapterId": "c1", "completed": false, "scrollPosition": 0.0,
                                "total": Int16(0), "progress": Int16.max, "dateRead": Date(timeIntervalSinceReferenceDate: 812_345_678.123456)]),
                new("History", ["sourceId": "test", "mangaId": "m2", "chapterId": "c2", "completed": true, "scrollPosition": -1.5,
                                "total": Int16.max, "progress": Int16.min, "dateRead": distantPast])
            ]
            for (index, history) in histories.enumerated() {
                history.setValue(chapters[index], forKey: "chapter")
            }
            for index in 0..<300 {
                let session = new("ReadingSession", [
                    "startDate": Date(timeIntervalSinceReferenceDate: Double(index) + 0.5),
                    "endDate": Date(timeIntervalSinceReferenceDate: Double(index) + 0.75), "pagesRead": Int16(index - 150)
                ])
                session.setValue(histories[0], forKey: "history")
            }
            new("ReadingSession", ["startDate": distantPast, "endDate": distantPast, "pagesRead": Int16.min])
                .setValue(histories[1], forKey: "history")

            new("MangaUpdate", ["sourceId": "test", "mangaId": "m2", "chapterId": "c1", "viewed": true, "date": distantPast])
                .setValue(chapters[1], forKey: "chapter")
            _ = new("MangaUpdate", ["sourceId": "test", "mangaId": "m2", "chapterId": nil, "viewed": false,
                                    "date": Date(timeIntervalSinceReferenceDate: 1)])

            // library: m1 (no category), m2 (in "uno"), 300 more (in "muchos 🙂"); "" has none
            let empty = new("Category", ["title": "", "data": nil, "group": false, "sort": Int16(0)])
            let uno = new("Category", ["title": "uno", "data": bytes, "group": true, "sort": Int16.min])
            let muchos = new("Category", ["title": "muchos 🙂", "data": Data(), "group": false, "sort": Int16.max])
            _ = empty
            new("LibraryManga", ["dateAdded": distantPast, "lastOpened": distantPast, "lastUpdated": distantPast,
                                 "lastUpdatedChapters": distantPast, "lastRead": nil, "lastChapter": nil])
                .setValue(m1, forKey: "manga")
            let entry2 = new("LibraryManga", ["dateAdded": Date(timeIntervalSinceReferenceDate: 2), "lastRead": distantPast,
                                              "lastChapter": Date(timeIntervalSinceReferenceDate: -2.5)])
            entry2.setValue(m2, forKey: "manga")
            uno.mutableSetValue(forKey: "libraryObjects").add(entry2)
            for index in 0..<300 {
                let manga = new("Manga", ["sourceId": "bulk", "id": "b\(index)", "title": "b\(index)"])
                let entry = new("LibraryManga", ["dateAdded": Date(timeIntervalSinceReferenceDate: Double(index))])
                entry.setValue(manga, forKey: "manga")
                muchos.mutableSetValue(forKey: "libraryObjects").add(entry)
            }

            _ = new("Track", ["id": "t", "trackerId": "anilist", "sourceId": "test", "mangaId": "m2", "title": nil, "chapterOffset": Int16.min])
            _ = new("Track", ["id": "t", "trackerId": "suwayomi", "sourceId": "test", "mangaId": "m2", "title": "", "chapterOffset": Int16.max])
            _ = new("Vocab", ["sourceId": "test", "mangaId": "m2", "chapterId": "c1", "word": "", "clozeOffset": nil,
                              "clozeText": nil, "reading": nil, "sentence": nil, "localImageId": nil, "page": Int16.min,
                              "createdDate": distantPast])
            _ = new("Vocab", ["sourceId": "test", "mangaId": "m2", "chapterId": "c1", "word": "漢字🙂", "clozeOffset": Int16.max,
                              "clozeText": "", "reading": "かんじ", "sentence": "a,b\n\"c\"", "localImageId": "", "page": Int16.max,
                              "createdDate": Date(timeIntervalSinceReferenceDate: 3)])
            let file = new("LocalFileInfo", ["path": "a/ñ 🙂.cbz", "dateCreated": nil, "dateModified": nil])
            file.setValue(m2, forKey: "manga")
            file.setValue(chapters[1], forKey: "chapter")
            _ = new("LocalFileInfo", ["path": "", "dateCreated": distantPast, "dateModified": Date(timeIntervalSinceReferenceDate: 4)])

            _ = new("Source", ["id": "s1", "apiVersion": "", "customSource": bytes, "listing": Int16.max, "path": nil])
            _ = new("Source", ["id": "s2", "apiVersion": "0.7", "customSource": nil, "listing": Int16.min, "path": ""])
            try context.save()
        }
        return directory
    }
}

/// P5: a container restored into the simulator (SUWA13_RESTAURADO = its Library/Application Support, copied out
/// with the app closed) holds the same data as the copy it came from (SUWA13_COPIA/<SUWA13_RESTAURADO_DE>).
@Suite struct StoreDumpRestoreTests {
    static let restored = ProcessInfo.processInfo.environment["SUWA13_RESTAURADO"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: restored != nil && copyFolder != nil))
    func theRestoredContainerHoldsTheCopy() throws {
        let device = ProcessInfo.processInfo.environment["SUWA13_RESTAURADO_DE"] ?? "ipad"
        let copy = try #require(copyFolder).appendingPathComponent(device).appendingPathComponent("Library/Application Support")
        let original = try StoreDump.dumpCopy(of: copy)
        let restored = try StoreDump.dumpCopy(of: try #require(Self.restored))
        try expectComplete(restored, stores: try #require(Self.restored))
        let tables = original.differences(to: restored).filter { $0.hasPrefix("tabla ") }
        if let out = ProcessInfo.processInfo.environment["SUWA13_OUT"] {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try (tables.joined(separator: "\n") + "\n")
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("restaurado-tablas.txt"), atomically: true, encoding: .utf8)
        }
        #expect(original.differences(to: restored, metadataTables: []) == [])
        #expect(restored.entities == original.entities)
        try restored.write(label: "restaurado-\(device)")
    }
}

// MARK: - Writing into a test store with sqlite (to fake what Core Data would not write)

enum SQLiteValue {
    case blob(Data)
    case double(Double)
}

/// Runs `sql` on the sqlite file at `path` (read-write), binding `values` to ?1, ?2…
func sqliteExec(_ path: String, _ sql: String, _ values: [SQLiteValue] = []) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw StoreDump.DumpError.sqlite("open") }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw StoreDump.DumpError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in values.enumerated() {
        switch value {
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32(data.count), transient) }
            case .double(let number):
                sqlite3_bind_double(statement, Int32(index + 1), number)
        }
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreDump.DumpError.sqlite(String(cString: sqlite3_errmsg(db))) }
    #expect(sqlite3_changes(db) > 0, "\(sql)")
}

/// The first column of the first row of `sql`, as bytes.
func sqliteBlob(_ path: String, _ sql: String) throws -> Data {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw StoreDump.DumpError.sqlite("open") }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement, sqlite3_step(statement) == SQLITE_ROW else {
        throw StoreDump.DumpError.sqlite(sql)
    }
    defer { sqlite3_finalize(statement) }
    let count = Int(sqlite3_column_bytes(statement, 0))
    return sqlite3_column_blob(statement, 0).map { Data(bytes: $0, count: count) } ?? Data()
}
