//
//  StoreDump.swift
//  AidokuTests
//
//  SUWA-13 F3 (T-R): a CANONICAL dump of every entity of the two stores (Aidoku.sqlite: Cloud; Local.sqlite: Local),
//  to prove that a later change of the data layer (Core Data → SwiftData) keeps everything. Rows are identified by
//  their natural key (never by objectID); relationships are the sorted natural keys of their destinations; rows
//  with a repeated key are all kept (sorted by content) and counted. Plus (T-M) the count and hash of the sqlite
//  metadata tables (CloudKit mirroring, persistent history, Core Data's own).
//
//  Transformables are the bytes in their sqlite column (never re-archived) and Floats carry the REAL in their column
//  too, both read with sqlite (read-only) from a copy of the store files.
//
//  Nothing readable leaves the test: the hashes are of the raw values, and the CSVs (only if SUWA13_OUT is set,
//  a folder outside the repo) carry titles, names, URLs and paths as hashes.
//

import CoreData
import CryptoKit
import Foundation
import SQLite3

@testable import Aidoku

struct StoreDump: Equatable {
    struct Entity: Equatable {
        var count = 0
        /// rows whose natural key is the same as the one of an earlier row
        var duplicateKeys = 0
        var sha256 = ""
        /// canonical lines, raw values (never written anywhere)
        var lines: [String] = []
        var csvHeader = ""
        var csvRows: [String] = []
    }

    struct Table: Equatable {
        var count = 0
        var sha256 = ""
        /// what is compared: the hash of the rows, but for Z_METADATA without the keys that may change
        var comparable = ""
        /// Z_METADATA only: "<Z_VERSION>/<plist key>" → hash of its value (to say which key differs)
        var keys: [String: String] = [:]
    }

    /// entity name → dump
    var entities: [String: Entity] = [:]
    /// file (Aidoku.sqlite / Local.sqlite) → every table in it
    var tableNames: [String: [String]] = [:]
    /// "file/table" → count and hash, only the metadata tables (prefixes in `metadataPrefixes`)
    var metadata: [String: Table] = [:]

    static let storeFiles = ["Aidoku.sqlite", "Local.sqlite"]
    static let metadataPrefixes = ["ANSCK", "ATRANSACTION", "ACHANGE", "Z_METADATA", "Z_MODELCACHE", "Z_PRIMARYKEY"]

    /// String attributes kept as they are in the CSVs (sources, trackers, languages); every other text goes as a
    /// hash, ids included (`id`, `mangaId`, `chapterId` are often slugs with the title).
    private static let plainStrings: Set<String> = ["sourceId", "trackerId", "lang", "apiVersion"]

    // MARK: - Entities

    /// Dump of every entity of the model, read through `context` (one fetch per entity, nothing is changed).
    static func make(context: NSManagedObjectContext) throws -> StoreDump {
        guard let coordinator = context.persistentStoreCoordinator else { return StoreDump() }
        let model = coordinator.managedObjectModel
        // the columns dumped as they are in sqlite (transformables, floats), from a copy of the store files
        let raw = try rawColumns(stores: coordinator.persistentStores.compactMap(\.url), model: model)
        return try context.performAndWait {
            var dump = StoreDump()
            // the model again inside: it is not Sendable
            guard let model = context.persistentStoreCoordinator?.managedObjectModel else { return dump }
            for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                guard let name = entity.name else { continue }
                dump.entities[name] = try entityDump(entity, context: context, raw: raw)
            }
            return dump
        }
    }

    private static func entityDump(_ entity: NSEntityDescription, context: NSManagedObjectContext, raw: RawColumns) throws -> Entity {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity.name!)
        request.includesSubentities = false
        request.returnsObjectsAsFaults = false
        request.relationshipKeyPathsForPrefetching = Array(entity.relationshipsByName.keys)
        let objects = try context.fetch(request)

        let attributes = entity.attributesByName.values.sorted { $0.name < $1.name }
        let relationships = entity.relationshipsByName.values.sorted { $0.name < $1.name }

        var rows: [(key: String, line: String, csv: String)] = []
        for object in objects {
            let key = naturalKey(object)
            var fields = [key]
            var csv = [csvKey(entity: entity.name!, key)]
            for attribute in attributes {
                let value = object.value(forKey: attribute.name)
                if readsRaw(attribute) {
                    let stored = try rawValue(object, attribute, raw)
                    if attribute.attributeType == .transformableAttributeType {
                        // the bytes in the column, as they are (no re-archiving)
                        fields.append(stored)
                        csv.append(stored == "∅" ? stored : "h:" + hash(stored))
                    } else {
                        // the Float Core Data gives and the REAL in the column
                        fields.append(canonical(value, attribute) + "/" + stored)
                        csv.append(canonical(value, attribute) + "/" + stored)
                    }
                } else {
                    fields.append(canonical(value, attribute))
                    csv.append(csvValue(value, attribute))
                }
            }
            for relationship in relationships {
                let destination = relationship.destinationEntity?.name ?? ""
                if relationship.isToMany {
                    let keys = ((object.value(forKey: relationship.name) as? Set<NSManagedObject>) ?? []).map(naturalKey).sorted()
                    fields.append("[" + keys.joined(separator: "\u{1F}") + "]")
                    csv.append("\(keys.count):" + hash(keys.map { csvKey(entity: destination, $0) }.joined(separator: ",")))
                } else if let target = object.value(forKey: relationship.name) as? NSManagedObject {
                    let targetKey = naturalKey(target)
                    fields.append(targetKey)
                    csv.append(csvKey(entity: destination, targetKey))
                } else {
                    fields.append("∅")
                    csv.append("∅")
                }
            }
            rows.append((key, fields.joined(separator: "\u{1E}"), csv.map(csvEscape).joined(separator: ",")))
        }
        rows.sort { $0.line < $1.line }

        var dump = Entity()
        dump.count = rows.count
        dump.duplicateKeys = rows.count - Set(rows.map(\.key)).count
        dump.lines = rows.map(\.line)
        dump.sha256 = sha(dump.lines.joined(separator: "\n"))
        dump.csvHeader = (["clave"] + attributes.map(\.name) + relationships.map(\.name)).joined(separator: ",")
        dump.csvRows = rows.map(\.csv)
        return dump
    }

    /// The natural key of a row (the logical identity the app uses), never its objectID.
    static func naturalKey(_ object: NSManagedObject) -> String {
        func text(_ key: String) -> String {
            switch object.value(forKey: key) {
                case let string as String: escaped(string)
                case let date as Date: dateString(date)
                case nil: "∅"
                case let other?: escaped("\(other)")
            }
        }
        func join(_ keys: String...) -> String { keys.map(text).joined(separator: "\u{1F}") }
        func related(_ key: String) -> String {
            (object.value(forKey: key) as? NSManagedObject).map(naturalKey) ?? "∅"
        }
        switch object.entity.name {
            case "Manga": return join("sourceId", "id")
            case "Chapter": return join("sourceId", "mangaId", "id")
            case "History": return join("sourceId", "mangaId", "chapterId")
            case "LibraryManga": return related("manga")
            case "Category": return join("title")
            case "Track": return join("id", "trackerId", "sourceId", "mangaId")
            case "MangaUpdate": return join("sourceId", "mangaId", "chapterId", "date")
            case "ReadingSession": return related("history") + "\u{1F}" + text("startDate")
            case "Vocab": return join("sourceId", "mangaId", "chapterId", "word", "createdDate")
            case "LocalFileInfo": return join("path")
            case "Source": return join("id")
            default: return "?" // a new entity: its key has to be added here
        }
    }

    /// The exact value, typed: nil is ∅ (never confused with 0, false or ""), floats and dates round-trip.
    static func canonical(_ value: Any?, _ attribute: NSAttributeDescription) -> String {
        guard let value, !(value is NSNull) else { return "∅" }
        switch attribute.attributeType {
            case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
                return "i\((value as? NSNumber)?.int64Value ?? 0)"
            case .booleanAttributeType:
                return (value as? NSNumber)?.boolValue == true ? "true" : "false"
            case .floatAttributeType:
                return "f\((value as? NSNumber)?.floatValue ?? .nan)"
            case .doubleAttributeType:
                return "d\((value as? NSNumber)?.doubleValue ?? .nan)"
            case .dateAttributeType:
                return (value as? Date).map(dateString) ?? "date?"
            case .stringAttributeType:
                return "s" + escaped((value as? String) ?? "")
            case .binaryDataAttributeType:
                return "x" + hex((value as? Data) ?? Data())
            default:
                return "\(value)"
        }
    }

    /// A text with the separators of the dump (U+1E between fields, U+1F inside a key) and the escape (U+1B)
    /// escaped, so that no text can look like two fields.
    static func escaped(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == "\u{1E}" || $0 == "\u{1F}" }) else { return text }
        return text
            .replacingOccurrences(of: "\u{1B}", with: "\u{1B}0")
            .replacingOccurrences(of: "\u{1E}", with: "\u{1B}1")
            .replacingOccurrences(of: "\u{1F}", with: "\u{1B}2")
    }

    /// Seconds since 2001-01-01 (what the store keeps), with all its decimals.
    static func dateString(_ date: Date) -> String {
        "t\(date.timeIntervalSinceReferenceDate)"
    }

    // MARK: - Columns read from sqlite

    /// "file/table" → Z_PK → column → typed value (∅, i…, d…, s…, x…), for the attributes in `readsRaw`.
    typealias RawColumns = [String: [Int64: [String: String]]]

    /// Transformables are dumped as the bytes in their column (two archives that decode the same are told apart),
    /// and Floats also with the REAL in their column (a REAL written with another precision shows).
    static func readsRaw(_ attribute: NSAttributeDescription) -> Bool {
        attribute.attributeType == .transformableAttributeType || attribute.attributeType == .floatAttributeType
    }

    static func tableName(_ entity: NSEntityDescription) -> String { "Z" + (entity.name ?? "").uppercased() }
    static func columnName(_ attribute: NSAttributeDescription) -> String { "Z" + attribute.name.uppercased() }

    /// The `readsRaw` columns of every entity, read-only with sqlite from a temporary copy of the store files.
    private static func rawColumns(stores: [URL], model: NSManagedObjectModel) throws -> RawColumns {
        var raw: RawColumns = [:]
        for directory in Set(stores.map { $0.deletingLastPathComponent() }) {
            let copy = try copyStores(from: directory)
            defer { try? FileManager.default.removeItem(at: copy) }
            for store in stores where store.deletingLastPathComponent() == directory {
                let file = store.lastPathComponent
                var db: OpaquePointer?
                guard sqlite3_open_v2(copy.appendingPathComponent(file).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                    throw DumpError.sqlite("open \(file)")
                }
                defer { sqlite3_close(db) }
                let tables = Set(try query(db, "SELECT name FROM sqlite_master WHERE type = 'table'").map { String($0[0].dropFirst()) })
                for entity in model.entities {
                    let columns = entity.attributesByName.values.filter(readsRaw).map(columnName).sorted()
                    let table = tableName(entity)
                    guard !columns.isEmpty, tables.contains(table) else { continue }
                    var rows: [Int64: [String: String]] = [:]
                    for row in try query(db, "SELECT Z_PK, \(columns.joined(separator: ", ")) FROM \(table)") {
                        guard let pk = Int64(row[0].dropFirst()) else { throw DumpError.raw("\(file)/\(table) Z_PK") }
                        rows[pk] = Dictionary(uniqueKeysWithValues: zip(columns, row.dropFirst()))
                    }
                    raw["\(file)/\(table)"] = rows
                }
            }
        }
        return raw
    }

    /// The column of this object's row (found by its Z_PK, from the objectID). Not found: the dump fails.
    private static func rawValue(_ object: NSManagedObject, _ attribute: NSAttributeDescription, _ raw: RawColumns) throws -> String {
        let file = object.objectID.persistentStore?.url?.lastPathComponent ?? "?"
        let table = "\(file)/\(tableName(object.entity))"
        guard
            !object.objectID.isTemporaryID,
            let pk = Int64(object.objectID.uriRepresentation().lastPathComponent.dropFirst()),
            let value = raw[table]?[pk]?[columnName(attribute)]
        else {
            throw DumpError.raw("\(table).\(columnName(attribute))")
        }
        return value
    }

    // MARK: - CSV (no readable text)

    private static func csvValue(_ value: Any?, _ attribute: NSAttributeDescription) -> String {
        let exact = canonical(value, attribute)
        guard value != nil, !(value is NSNull) else { return exact }
        switch attribute.attributeType {
            case .stringAttributeType:
                return plainStrings.contains(attribute.name) ? exact : "h:" + hash(exact)
            case .binaryDataAttributeType:
                return "h:" + hash(exact)
            default:
                return exact
        }
    }

    /// Natural keys carry ids, titles, paths or words: always a hash in the CSVs.
    private static func csvKey(entity: String, _ key: String) -> String {
        "h:" + hash(key)
    }

    private static func csvEscape(_ field: String) -> String {
        field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
            ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : field
    }

    // MARK: - Metadata that changes when the app opens a store

    /// The only key of the store's metadata plist (Z_METADATA) that may change when the app's stack opens a copy
    /// without CloudKit and saves nothing: Core Data rewrites it when it saves and closes a store last written by
    /// another version of the framework (measured in F3 P4: the iPad copy, from iPadOS 27.2, says 1634; the iOS 27.0
    /// simulator writes 1629; the iPhone copy, from iOS 27.0.1, already said 1629). Every other key (NSStoreUUID,
    /// model hashes and identifiers, any new one), the other columns of Z_METADATA and every other metadata table
    /// (CloudKit mirroring ANSCK*, persistent history, primary keys, model cache) must stay as they were.
    static let metadataKeysThatChange: Set<String> = ["NSPersistenceFrameworkVersion"]

    /// Z_METADATA rows with the plist decoded and canonical, without `metadataKeysThatChange`; the plist must be a
    /// dictionary (if not, the dump fails).
    private static func metadataPlist(_ db: OpaquePointer) throws -> (comparable: String, keys: [String: String]) {
        var statement: OpaquePointer?
        let sql = "SELECT Z_VERSION, Z_UUID, Z_PLIST FROM Z_METADATA ORDER BY Z_VERSION"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DumpError.sqlite(sql) }
        defer { sqlite3_finalize(statement) }
        var lines: [String] = []
        var keys: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let version = sqlite3_column_int64(statement, 0)
            let uuid = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "∅"
            let count = Int(sqlite3_column_bytes(statement, 2))
            guard
                let bytes = sqlite3_column_blob(statement, 2),
                let plist = try PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: count), options: 0, format: nil) as? [String: Any]
            else {
                throw DumpError.sqlite("Z_METADATA: Z_PLIST is not a dictionary")
            }
            let kept = plist.filter { !metadataKeysThatChange.contains($0.key) }
            for (key, value) in kept {
                keys["\(version)/\(key)"] = hash(plistText(value))
            }
            lines.append("i\(version)\u{1E}" + plistText(uuid) + "\u{1E}" + plistText(kept))
        }
        return (sha(lines.joined(separator: "\n")), keys)
    }

    /// A plist value as text that cannot be ambiguous (strings carry their length; dictionaries are sorted).
    static func plistText(_ value: Any) -> String {
        switch value {
            case let dictionary as [String: Any]:
                return "{" + dictionary.keys.sorted().map { plistText($0) + "=" + plistText(dictionary[$0]!) }.joined(separator: ";") + "}"
            case let array as [Any]:
                return "[" + array.map(plistText).joined(separator: ",") + "]"
            case let string as String:
                return "s\(string.utf8.count):" + string
            case let data as Data:
                return "x" + hex(data)
            case let date as Date:
                return dateString(date)
            case let number as NSNumber:
                return CFGetTypeID(number) == CFBooleanGetTypeID() ? "b\(number.boolValue)" : "n" + number.stringValue
            default:
                return "?\(type(of: value))"
        }
    }

    /// Rows of a table, counted with sqlite (read-only, on a temporary copy): the oracle for the dump's counts.
    static func sqliteCount(in directory: URL, file: String, table: String) throws -> Int {
        let copy = try copyStores(from: directory)
        defer { try? FileManager.default.removeItem(at: copy) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.appendingPathComponent(file).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw DumpError.sqlite("open \(file)")
        }
        defer { sqlite3_close(db) }
        return Int(try query(db, "SELECT COUNT(*) FROM \"\(table)\"")[0][0].dropFirst()) ?? -1
    }

    // MARK: - sqlite tables (T-M)

    /// Every table of each store file in `directory` and, for the metadata ones, count and hash of all their rows.
    /// Read-only (SQLITE_OPEN_READONLY) on a temporary copy of the three files of each store.
    static func tables(in directory: URL) throws -> (names: [String: [String]], metadata: [String: Table]) {
        var names: [String: [String]] = [:]
        var metadata: [String: Table] = [:]
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("suwa13-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for file in storeFiles {
            for suffix in ["", "-wal", "-shm"] {
                let source = directory.appendingPathComponent(file + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: copy.appendingPathComponent(file + suffix))
                }
            }
            let path = copy.appendingPathComponent(file).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                throw DumpError.sqlite("open \(file)")
            }
            defer { sqlite3_close(db) }
            let tables = try query(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { String($0[0].dropFirst()) }
            names[file] = tables
            for table in tables where metadataPrefixes.contains(where: { table.hasPrefix($0) }) {
                let columns = try query(db, "SELECT COUNT(*) FROM pragma_table_info('\(table)')")[0][0]
                let order = (1...max(1, Int(columns.dropFirst()) ?? 1)).map(String.init).joined(separator: ",")
                let rows = try query(db, "SELECT * FROM \"\(table)\" ORDER BY \(order)")
                var entry = Table(count: rows.count, sha256: sha(rows.map { $0.joined(separator: "\u{1E}") }.joined(separator: "\n")))
                if table == "Z_METADATA" {
                    (entry.comparable, entry.keys) = try metadataPlist(db)
                } else {
                    entry.comparable = entry.sha256
                }
                metadata["\(file)/\(table)"] = entry
            }
        }
        return (names, metadata)
    }

    enum DumpError: Error {
        case sqlite(String)
        /// a column the dump reads from sqlite was not found for a row
        case raw(String)
    }

    /// Rows of a query, each value typed (∅, i…, d…, s…, x…).
    private static func query(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DumpError.sqlite(sql + ": " + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                    case SQLITE_NULL: row.append("∅")
                    case SQLITE_INTEGER: row.append("i\(sqlite3_column_int64(statement, column))")
                    case SQLITE_FLOAT: row.append("d\(sqlite3_column_double(statement, column))")
                    case SQLITE_TEXT: row.append("s" + escaped(String(cString: sqlite3_column_text(statement, column))))
                    default:
                        let count = Int(sqlite3_column_bytes(statement, column))
                        let bytes = sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()
                        row.append("x" + hex(bytes))
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Opening a copy

    /// The app's model (the same instance the app loaded: one class per entity).
    static var model: NSManagedObjectModel { CoreDataManager.shared.container.managedObjectModel }

    /// A new temporary folder with a copy of the store files of `folder` (the three files of each store).
    static func copyStores(from folder: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("suwa13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        for file in storeFiles {
            for suffix in ["", "-wal", "-shm"] {
                let source = folder.appendingPathComponent(file + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: copy.appendingPathComponent(file + suffix))
                }
            }
        }
        return copy
    }

    /// Opens a COPY of the stores in `folder` (Aidoku.sqlite and Local.sqlite with their -wal/-shm) read-only,
    /// dumps the entities and the sqlite tables of the same copy, and removes the copy.
    static func dumpCopy(of folder: URL) throws -> StoreDump {
        let copy = try copyStores(from: folder)
        defer { try? FileManager.default.removeItem(at: copy) }
        // the tables first, before Core Data opens (and checkpoints) the copy
        let tables = try tables(in: copy)
        let container = NSPersistentContainer(name: "Aidoku", managedObjectModel: model)
        container.persistentStoreDescriptions = storeFiles.map { file in
            let description = NSPersistentStoreDescription(url: copy.appendingPathComponent(file))
            description.configuration = file == "Aidoku.sqlite" ? "Cloud" : "Local"
            description.isReadOnly = true
            description.shouldMigrateStoreAutomatically = false
            description.shouldInferMappingModelAutomatically = false
            if file == "Aidoku.sqlite" {
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            }
            description.shouldAddStoreAsynchronously = false
            return description
        }
        try load(container)
        defer { close(container) }
        var dump = try make(context: container.newBackgroundContext())
        dump.tableNames = tables.names
        dump.metadata = tables.metadata
        return dump
    }

    static func load(_ container: NSPersistentContainer) throws {
        var loadError: Error?
        container.loadPersistentStores { _, error in
            if let error { loadError = error }
        }
        if let loadError { throw loadError }
    }

    static func close(_ container: NSPersistentContainer) {
        for store in container.persistentStoreCoordinator.persistentStores {
            try? container.persistentStoreCoordinator.remove(store)
        }
    }

    /// The app's stack, as `CoreDataManager.createContainer(usesCloudKitMirroring: false)` builds it (the same
    /// container class, descriptions, options and merge policy), on the stores of `directory` instead of the app's.
    static func appContainer(directory: URL) throws -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(name: "Aidoku", managedObjectModel: model)

        let cloudDescription = NSPersistentStoreDescription(url: directory.appendingPathComponent("Aidoku.sqlite"))
        cloudDescription.configuration = "Cloud"
        cloudDescription.shouldMigrateStoreAutomatically = true
        cloudDescription.shouldInferMappingModelAutomatically = true
        cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        let localDescription = NSPersistentStoreDescription(url: directory.appendingPathComponent("Local.sqlite"))
        localDescription.configuration = "Local"
        localDescription.shouldMigrateStoreAutomatically = true
        localDescription.shouldInferMappingModelAutomatically = true

        cloudDescription.cloudKitContainerOptions = nil
        container.persistentStoreDescriptions = [cloudDescription, localDescription]
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        try load(container)
        return container
    }

    // MARK: - Comparing and writing

    /// What differs, without readable text: per entity the counts and the first different row in its CSV form;
    /// per metadata table (only those in `tables`, or all if nil) count and hash (for Z_METADATA, key by key
    /// without `metadataKeysThatChange`, naming the keys that differ).
    func differences(to other: StoreDump, metadataTables: Set<String>? = nil) -> [String] {
        var out: [String] = []
        for name in Set(entities.keys).union(other.entities.keys).sorted() {
            let mine = entities[name] ?? Entity()
            let theirs = other.entities[name] ?? Entity()
            guard mine.sha256 != theirs.sha256 || mine.count != theirs.count else { continue }
            var line = "\(name): \(mine.count) filas → \(theirs.count)"
            let common = min(mine.lines.count, theirs.lines.count)
            let firstDifferent = (0..<common).first { mine.lines[$0] != theirs.lines[$0] }
            if let index = firstDifferent ?? (mine.lines.count != theirs.lines.count ? common : nil) {
                let before = index < mine.csvRows.count ? mine.csvRows[index] : "—"
                let after = index < theirs.csvRows.count ? theirs.csvRows[index] : "—"
                line += "; primera fila distinta (#\(index)): \(before)  →  \(after)"
            }
            out.append(line)
        }
        for table in Set(metadata.keys).union(other.metadata.keys).sorted() where metadataTables?.contains(table) ?? true {
            let mine = metadata[table]
            let theirs = other.metadata[table]
            if mine?.count != theirs?.count || mine?.comparable != theirs?.comparable {
                let describe = { (table: Table?) in table.map { "\($0.count) filas \($0.comparable.prefix(12))" } ?? "no está" }
                var line = "tabla \(table): \(describe(mine)) → \(describe(theirs))"
                let keys = Set(mine?.keys.keys ?? [:].keys).union(theirs?.keys.keys ?? [:].keys)
                let changed = keys.filter { mine?.keys[$0] != theirs?.keys[$0] }.sorted()
                if !changed.isEmpty {
                    line += "; claves distintas: " + changed.joined(separator: ", ")
                }
                out.append(line)
            }
        }
        return out
    }

    /// Summary lines (only numbers and hashes).
    var summary: [String] {
        entities.keys.sorted().map { name in
            let entity = entities[name]!
            return "\(name) filas=\(entity.count) claves-repetidas=\(entity.duplicateKeys) sha256=\(entity.sha256)"
        } + metadata.keys.sorted().map { table in
            let entry = metadata[table]!
            return "tabla \(table) filas=\(entry.count) sha256=\(entry.sha256)"
                + (entry.comparable == entry.sha256 ? "" : " comparable=\(entry.comparable)")
        }
    }

    /// Writes the summary and one CSV per entity to $SUWA13_OUT/<label>/ (nothing if the variable is not set).
    func write(label: String) throws {
        guard let out = ProcessInfo.processInfo.environment["SUWA13_OUT"] else { return }
        let folder = URL(fileURLWithPath: out).appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (summary.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("resumen.txt"), atomically: true, encoding: .utf8)
        let tableList = tableNames.keys.sorted().flatMap { file in tableNames[file]!.map { "\(file)/\($0)" } }
        try (tableList.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("tablas.txt"), atomically: true, encoding: .utf8)
        for (name, entity) in entities {
            try ([entity.csvHeader] + entity.csvRows).joined(separator: "\n")
                .appending("\n")
                .write(to: folder.appendingPathComponent("\(name).csv"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Hashes

    static func sha(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ text: String) -> String { String(sha(text).prefix(16)) }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
