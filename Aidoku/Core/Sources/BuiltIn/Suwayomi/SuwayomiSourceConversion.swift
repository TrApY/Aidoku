//
//  SuwayomiSourceConversion.swift
//  Aidoku
//
//  SUWA-12 D6: the library saved under the single Suwayomi source (the parent, now only the connection)
//  moves to the server source of each manga, without losing anything. Manga and chapter ids are the
//  server's own (the same with any key of that server), so only the source key changes: in Core Data
//  (Manga, Chapter, History, MangaUpdate, Track, Vocab), in the per-manga settings, in the settings that
//  hold source keys and in the downloads folder.
//
//  Derived from the data (rows still under a parent key), not from a «done» flag: an old backup or iCloud
//  bringing old rows back is converted again. Idempotent. Nothing is written before the server says
//  where each manga is and a backup has been saved; a manga the server doesn't know (or whose source
//  isn't on it) stays under the parent, which still reads it, and counts as pending.
//

import AidokuRunner
import CoreData
import Foundation

enum SuwayomiSourceConversion {
    /// Entities with a denormalized `sourceId` (model 0.9).
    static let entities = ["Manga", "Chapter", "History", "MangaUpdate", "Track", "Vocab"]

    struct Environment: @unchecked Sendable {
        var container: NSPersistentContainer
        var defaults: UserDefaults
        /// The persistent domain of `defaults` (registered defaults are not settings to move).
        var defaultsDomain: String
        var downloadsDirectory: URL
        /// The server source of each manga id the server knows (a batch; throws = server down).
        var resolve: @Sendable (_ connectionKey: String, _ mangaIds: [String]) async throws -> [String: String]
        /// The children registered for a connection.
        var children: @Sendable (_ parentKey: String) async -> [SuwayomiServerSourceConfig]
        /// Saves a backup «antes-SUWA-12»; false = not saved (then nothing is converted).
        var backup: @Sendable () async -> Bool
        /// Downloads were moved: caches of the downloads folder must be reloaded.
        var downloadsMoved: @Sendable () async -> Void = {}
    }

    struct Report: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case nothingToConvert
            case serverUnavailable
            case backupFailed
            case done
        }
        var outcome: Outcome
        var converted = 0
        /// Unknown to the server or with a source not on it: still under the parent.
        var pending = 0
        /// Couldn't be rewritten (left as they were).
        var failed = 0
        /// Rows that already existed under the new key (iCloud, an interrupted conversion) and were merged.
        var merged = 0
        /// Manga ids still under a parent after this run.
        var pendingIds: [String: [String]] = [:]
    }

    /// Converts what is under each of `parentKeys`.
    static func run(parentKeys: [String], environment env: Environment) async -> Report {
        // 1. what is there to convert (no writes)
        var idsByParent: [String: [String]] = [:]
        for parent in parentKeys {
            let ids = await mangaIds(under: parent, env: env)
            if !ids.isEmpty {
                idsByParent[parent] = ids
            }
        }
        guard !idsByParent.isEmpty else {
            await rewriteSourceKeySettings(parentKeys: parentKeys, moved: [:], env: env)
            return .init(outcome: .nothingToConvert)
        }

        // 2. where each manga is (no writes); a server that doesn't answer: nothing now, next start again
        var targets: [String: [String: String]] = [:] // parent → manga id → child key
        var report = Report(outcome: .done)
        for (parent, ids) in idsByParent {
            let serverSources: [String: String]
            do {
                serverSources = try await env.resolve(parent, ids)
            } catch {
                LogManager.logger.warn("Suwayomi conversion of \(parent) postponed, the server didn't answer: \(error)")
                return .init(outcome: .serverUnavailable)
            }
            let children = Dictionary(
                (await env.children(parent)).filter(\.available).map { ($0.serverSourceId, $0.key) },
                uniquingKeysWith: { first, _ in first }
            )
            var map: [String: String] = [:]
            for id in ids {
                if let serverSource = serverSources[id], let child = children[serverSource] {
                    map[id] = child
                } else {
                    report.pending += 1
                    report.pendingIds[parent, default: []].append(id)
                }
            }
            targets[parent] = map
        }
        guard targets.values.contains(where: { !$0.isEmpty }) else {
            await rewriteSourceKeySettings(parentKeys: parentKeys, moved: [:], env: env)
            log(report)
            return report
        }

        // 3. a backup before writing anything
        guard await env.backup() else {
            LogManager.logger.error("Suwayomi conversion not done: the backup before it couldn't be saved")
            return .init(outcome: .backupFailed)
        }

        // 4. per manga: downloads, Core Data (one save), settings
        var anyDownloadMoved = false
        for (parent, map) in targets {
            for (mangaId, child) in map.sorted(by: { $0.key < $1.key }) {
                let moves = moveDownloads(parent: parent, child: child, mangaId: mangaId, env: env)
                guard let moves else {
                    report.failed += 1
                    report.pendingIds[parent, default: []].append(mangaId)
                    continue
                }
                let merged = await rekey(parent: parent, child: child, mangaId: mangaId, env: env)
                guard let merged else {
                    undo(moves)
                    report.failed += 1
                    report.pendingIds[parent, default: []].append(mangaId)
                    continue
                }
                if !moves.isEmpty {
                    anyDownloadMoved = true
                }
                report.merged += merged
                moveMangaSettings(parent: parent, child: child, mangaId: mangaId, env: env)
                report.converted += 1
            }
        }

        // 5. settings holding source keys
        await rewriteSourceKeySettings(parentKeys: parentKeys, moved: targets, env: env)
        if anyDownloadMoved {
            await env.downloadsMoved()
        }
        log(report)
        return report
    }

    private static func log(_ report: Report) {
        LogManager.logger.info(
            "Suwayomi conversion: \(report.converted) converted, \(report.pending) pending, "
                + "\(report.failed) failed, \(report.merged) merged rows"
        )
    }
}

// MARK: What is under a parent
extension SuwayomiSourceConversion {
    /// Manga ids with anything under `parent`: rows of any entity, per-manga settings, download folders.
    static func mangaIds(under parent: String, env: Environment) async -> [String] {
        var ids = Set<String>()
        let context = env.container.newBackgroundContext()
        let fromData: Set<String> = await context.perform {
            var ids = Set<String>()
            for entity in entities {
                let request = NSFetchRequest<NSDictionary>(entityName: entity)
                request.predicate = NSPredicate(format: "sourceId == %@", parent)
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = [entity == "Manga" ? "id" : "mangaId"]
                request.returnsDistinctResults = true
                for row in (try? context.fetch(request)) ?? [] {
                    if let id = row[entity == "Manga" ? "id" : "mangaId"] as? String, !id.isEmpty {
                        ids.insert(id)
                    }
                }
            }
            return ids
        }
        ids.formUnion(fromData)
        for key in settingKeys(env: env) {
            if let (_, mangaId) = perMangaKey(key, parent: parent) {
                ids.insert(mangaId)
            }
        }
        let folder = env.downloadsDirectory.appendingSafePathComponent(parent)
        for manga in folder.contents where manga.isDirectory {
            ids.insert(manga.lastPathComponent)
        }
        return ids.sorted()
    }

    private static func settingKeys(env: Environment) -> [String] {
        Array((env.defaults.persistentDomain(forName: env.defaultsDomain) ?? [:]).keys)
    }

    /// `<prefix>.<parent>.<mangaId>` (Reader.readingMode, Reader.pagedPageOffset, Manga.chapterDisplayMode,
    /// DownloadAhead, …): the prefix and the manga id. The parent's own settings (`<parent>.…`) are not.
    static func perMangaKey(_ key: String, parent: String) -> (prefix: String, mangaId: String)? {
        let marker = ".\(parent)."
        guard let range = key.range(of: marker, options: .backwards) else { return nil }
        let prefix = String(key[..<range.lowerBound])
        let mangaId = String(key[range.upperBound...])
        guard
            !prefix.isEmpty,
            !mangaId.isEmpty,
            !mangaId.contains("."),
            !prefix.hasPrefix(SuwayomiSourceRunner.sourceKeyPrefix) // a source's own setting
        else { return nil }
        return (prefix, mangaId)
    }
}

// MARK: Core Data
extension SuwayomiSourceConversion {
    /// Moves every row of (`parent`, `mangaId`) to `child` in one save; rows that already exist under
    /// `child` are merged keeping the most complete. Returns the merged rows, nil if it couldn't be saved.
    static func rekey(parent: String, child: String, mangaId: String, env: Environment) async -> Int? {
        let context = env.container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        return await context.perform {
            var merged = 0
            func fetch(_ entity: String, _ format: String, _ args: [Any]) -> [NSManagedObject] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: format, argumentArray: args)
                return (try? context.fetch(request)) ?? []
            }

            // Manga
            for old in fetch("Manga", "sourceId == %@ AND id == %@", [parent, mangaId]) {
                if let existing = fetch("Manga", "sourceId == %@ AND id == %@", [child, mangaId]).first(where: { $0 != old }) {
                    mergeManga(old, into: existing)
                    context.delete(old)
                    merged += 1
                } else {
                    old.setValue(child, forKey: "sourceId")
                }
            }
            // Chapter
            for old in fetch("Chapter", "sourceId == %@ AND mangaId == %@", [parent, mangaId]) {
                let chapterId = old.value(forKey: "id") as? String ?? ""
                if let existing = fetch("Chapter", "sourceId == %@ AND mangaId == %@ AND id == %@", [child, mangaId, chapterId])
                    .first(where: { $0 != old })
                {
                    mergeChapter(old, into: existing)
                    context.delete(old)
                    merged += 1
                } else {
                    old.setValue(child, forKey: "sourceId")
                }
            }
            // History
            for old in fetch("History", "sourceId == %@ AND mangaId == %@", [parent, mangaId]) {
                let chapterId = old.value(forKey: "chapterId") as? String ?? ""
                if let existing = fetch("History", "sourceId == %@ AND mangaId == %@ AND chapterId == %@", [child, mangaId, chapterId])
                    .first(where: { $0 != old })
                {
                    let (keep, drop) = mostComplete(old, existing)
                    keep.setValue(child, forKey: "sourceId")
                    moveSessions(from: drop, to: keep)
                    if keep.value(forKey: "chapter") == nil, let chapter = drop.value(forKey: "chapter") {
                        keep.setValue(chapter, forKey: "chapter")
                    }
                    context.delete(drop)
                    merged += 1
                } else {
                    old.setValue(child, forKey: "sourceId")
                }
            }
            // MangaUpdate
            for old in fetch("MangaUpdate", "sourceId == %@ AND mangaId == %@", [parent, mangaId]) {
                let chapterId = old.value(forKey: "chapterId") as? String ?? ""
                if fetch("MangaUpdate", "sourceId == %@ AND mangaId == %@ AND chapterId == %@", [child, mangaId, chapterId])
                    .contains(where: { $0 != old })
                {
                    context.delete(old)
                    merged += 1
                } else {
                    old.setValue(child, forKey: "sourceId")
                }
            }
            // Track: the id (`<parent>|<id>`) is kept, the connection of the parent resolves it
            for old in fetch("Track", "sourceId == %@ AND mangaId == %@", [parent, mangaId]) {
                let trackerId = old.value(forKey: "trackerId") as? String ?? ""
                if fetch("Track", "sourceId == %@ AND mangaId == %@ AND trackerId == %@", [child, mangaId, trackerId])
                    .contains(where: { $0 != old })
                {
                    context.delete(old)
                    merged += 1
                } else {
                    old.setValue(child, forKey: "sourceId")
                }
            }
            // Vocab: entries of their own, never merged
            for old in fetch("Vocab", "sourceId == %@ AND mangaId == %@", [parent, mangaId]) {
                old.setValue(child, forKey: "sourceId")
            }

            do {
                if context.hasChanges {
                    try context.save()
                }
                return merged
            } catch {
                LogManager.logger.error("Suwayomi conversion of manga \(mangaId) not saved: \(error)")
                context.rollback()
                return nil
            }
        }
    }

    /// The old manga goes; what only it has goes to the one kept (library entry, chapters, files).
    private static func mergeManga(_ old: NSManagedObject, into kept: NSManagedObject) {
        if let library = old.value(forKey: "libraryObject") as? NSManagedObject {
            if let keptLibrary = kept.value(forKey: "libraryObject") as? NSManagedObject {
                // both in the library: the categories of both (the old entry goes with the old manga)
                let categories = (keptLibrary.value(forKey: "categories") as? Set<NSManagedObject> ?? [])
                    .union(library.value(forKey: "categories") as? Set<NSManagedObject> ?? [])
                keptLibrary.setValue(categories, forKey: "categories")
            } else {
                library.setValue(kept, forKey: "manga")
            }
        }
        for chapter in (old.value(forKey: "chapters") as? Set<NSManagedObject>) ?? [] {
            chapter.setValue(kept, forKey: "manga")
        }
        if kept.value(forKey: "fileInfo") == nil, let file = old.value(forKey: "fileInfo") as? NSManagedObject {
            file.setValue(kept, forKey: "manga")
        }
        // fields only the old one has
        for (name, _) in kept.entity.attributesByName where kept.value(forKey: name) == nil {
            if name != "sourceId", let value = old.value(forKey: name) {
                kept.setValue(value, forKey: name)
            }
        }
    }

    private static func mergeChapter(_ old: NSManagedObject, into kept: NSManagedObject) {
        for relation in ["history", "mangaUpdate", "fileInfo", "manga"] where kept.value(forKey: relation) == nil {
            if let value = old.value(forKey: relation) {
                kept.setValue(value, forKey: relation)
            }
        }
    }

    /// Of two histories of one chapter, the one to keep: completed, then more progress, then the latest read.
    static func mostComplete(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> (keep: NSManagedObject, drop: NSManagedObject) {
        func rank(_ history: NSManagedObject) -> (Int, Int, Date) {
            (
                (history.value(forKey: "completed") as? Bool ?? false) ? 1 : 0,
                Int(history.value(forKey: "progress") as? Int16 ?? 0),
                history.value(forKey: "dateRead") as? Date ?? .distantPast
            )
        }
        return rank(rhs) > rank(lhs) ? (rhs, lhs) : (lhs, rhs)
    }

    private static func moveSessions(from drop: NSManagedObject, to keep: NSManagedObject) {
        for session in (drop.value(forKey: "sessions") as? Set<NSManagedObject>) ?? [] {
            session.setValue(keep, forKey: "history")
        }
    }
}

// MARK: Downloads and settings
extension SuwayomiSourceConversion {
    struct Move {
        let from: URL
        let to: URL
    }

    /// Moves `Downloads/<parent>/<mangaId>` to `Downloads/<child>/<mangaId>` (into an existing folder: only
    /// what isn't there, nothing overwritten). The moves done, or nil if one failed (the others undone).
    static func moveDownloads(parent: String, child: String, mangaId: String, env: Environment) -> [Move]? {
        let source = env.downloadsDirectory.appendingSafePathComponent(parent).appendingSafePathComponent(mangaId)
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let destinationFolder = env.downloadsDirectory.appendingSafePathComponent(child)
        let destination = destinationFolder.appendingSafePathComponent(mangaId)
        var moves: [Move] = []
        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: source, to: destination)
                moves.append(.init(from: source, to: destination))
            } else {
                let items = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for item in items {
                    let target = destination.appendingPathComponent(item.lastPathComponent)
                    guard !FileManager.default.fileExists(atPath: target.path) else { continue } // kept where it was
                    try FileManager.default.moveItem(at: item, to: target)
                    moves.append(.init(from: item, to: target))
                }
                if (try? FileManager.default.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: source)
                }
            }
        } catch {
            LogManager.logger.error("Suwayomi conversion: downloads of \(mangaId) not moved: \(error)")
            undo(moves)
            return nil
        }
        let parentFolder = env.downloadsDirectory.appendingSafePathComponent(parent)
        if (try? FileManager.default.contentsOfDirectory(atPath: parentFolder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: parentFolder)
        }
        return moves
    }

    static func undo(_ moves: [Move]) {
        for move in moves.reversed() {
            try? FileManager.default.createDirectory(at: move.from.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: move.to, to: move.from)
        }
    }

    /// Per-manga settings: copied to the child's key, then the old one removed (a value already under the
    /// new key wins).
    static func moveMangaSettings(parent: String, child: String, mangaId: String, env: Environment) {
        for key in settingKeys(env: env) {
            guard let (prefix, id) = perMangaKey(key, parent: parent), id == mangaId else { continue }
            let newKey = "\(prefix).\(child).\(mangaId)"
            if env.defaults.object(forKey: newKey) == nil, let value = env.defaults.object(forKey: key) {
                env.defaults.set(value, forKey: newKey)
            }
            if env.defaults.object(forKey: newKey) != nil {
                env.defaults.removeObject(forKey: key)
            }
        }
    }

    /// Settings whose values hold source keys: pinned sources, disabled sources, library filters, the
    /// download queue and the chapters waiting to be deleted.
    static func rewriteSourceKeySettings(parentKeys: [String], moved: [String: [String: String]], env: Environment) async {
        let defaults = env.defaults
        for parent in parentKeys {
            // a connection is not a source to pin: unpinned, nothing new pinned
            if var pinned = defaults.stringArray(forKey: AppSettings.browse.pinnedList.key), pinned.contains(parent) {
                pinned.removeAll { $0 == parent }
                defaults.set(pinned, forKey: AppSettings.browse.pinnedList.key)
            }
            // a disabled connection: its server sources disabled too
            if
                var disabled = defaults.stringArray(forKey: AppSettings.browse.disabledSources.key),
                disabled.contains(parent)
            {
                let children = await env.children(parent).map(\.key)
                for key in children where !disabled.contains(key) {
                    disabled.append(key)
                }
                defaults.set(disabled, forKey: AppSettings.browse.disabledSources.key)
            }
        }
        await rewriteLibraryFilters(parentKeys: parentKeys, env: env)
        let map = moved
        rewriteJSON(key: "Data.downloadQueueState", env: env) { value in
            rewriteQueue(value, moved: map)
        }
        rewriteJSON(key: "Data.chaptersToBeDeleted", env: env) { value in
            rewriteSourceKeys(value, moved: map)
        }
        // pending page updates: the chapter's source changes, the track id (`<parent>|<id>`) stays
        rewriteJSON(key: "Tracker.pageTrackingState", env: env) { value in
            rewriteSourceKeys(value, moved: map)
        }
    }

    /// A library filter «source = parent» becomes one per server source with library manga (included ones
    /// are an OR, excluded ones an AND), plus the parent while it still has some.
    private static func rewriteLibraryFilters(parentKeys: [String], env: Environment) async {
        let key = AppSettings.library.filtersData.key
        guard
            let data = env.defaults.data(forKey: key),
            let filters = try? JSONDecoder().decode([LibraryFilter].self, from: data),
            filters.contains(where: { $0.type == .source && parentKeys.contains($0.value ?? "") })
        else { return }
        let context = env.container.newBackgroundContext()
        let librarySources: Set<String> = await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "LibraryManga")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["manga.sourceId"]
            request.returnsDistinctResults = true
            return Set(((try? context.fetch(request)) ?? []).compactMap { $0["manga.sourceId"] as? String })
        }
        var result: [LibraryFilter] = []
        for filter in filters {
            guard filter.type == .source, let parent = filter.value, parentKeys.contains(parent) else {
                if !result.contains(filter) { result.append(filter) }
                continue
            }
            let keys = librarySources.filter { $0 == parent || $0.hasPrefix("\(parent).") }.sorted()
            for sourceKey in keys {
                var copy = filter
                copy.value = sourceKey
                if !result.contains(copy) { result.append(copy) }
            }
        }
        if result != filters, let newData = try? JSONEncoder().encode(result) {
            env.defaults.set(newData, forKey: key)
        }
    }

    private static func rewriteJSON(key: String, env: Environment, _ transform: (Any) -> Any) {
        guard
            let data = env.defaults.data(forKey: key),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return }
        let newValue = transform(value)
        // only a real change is written (the same JSON can come out in another key order)
        guard !(newValue as AnyObject).isEqual(value) else { return }
        if let newData = try? JSONSerialization.data(withJSONObject: newValue) {
            env.defaults.set(newData, forKey: key)
        }
    }

    /// Any `{"sourceKey": parent, "mangaKey"|"key": id}` of a converted manga gets the child key.
    static func rewriteSourceKeys(_ value: Any, moved: [String: [String: String]]) -> Any {
        if let array = value as? [Any] {
            return array.map { rewriteSourceKeys($0, moved: moved) }
        }
        guard var object = value as? [String: Any] else { return value }
        for (name, inner) in object {
            object[name] = rewriteSourceKeys(inner, moved: moved)
        }
        if
            let sourceKey = object["sourceKey"] as? String,
            let mangaId = (object["mangaKey"] as? String) ?? (object["key"] as? String),
            let child = moved[sourceKey]?[mangaId]
        {
            object["sourceKey"] = child
        }
        return object
    }

    /// The download queue is grouped by source key: each download goes to its (new) source.
    static func rewriteQueue(_ value: Any, moved: [String: [String: String]]) -> Any {
        guard let queue = value as? [String: Any] else { return value }
        var result: [String: [Any]] = [:]
        for (sourceKey, downloads) in queue {
            for download in (downloads as? [Any]) ?? [] {
                let rewritten = rewriteSourceKeys(download, moved: moved)
                let key = ((rewritten as? [String: Any])?["chapterIdentifier"] as? [String: Any])?["sourceKey"] as? String ?? sourceKey
                result[key, default: []].append(rewritten)
            }
            if (downloads as? [Any])?.isEmpty == true, result[sourceKey] == nil {
                result[sourceKey] = []
            }
        }
        return result
    }
}
