//
//  BackupManager.swift
//  Aidoku
//
//  Created by Skitty on 2/26/22.
//

import BackgroundTasks
import CoreData
import Foundation
import UIKit

actor BackupManager {
    static let shared = BackupManager()

    static let directory = FileManager.default.documentDirectory.appendingPathComponent("Backups", isDirectory: true)

    static var backupUrls: [URL] {
        Self.directory.contentsByDateModified
    }

    private static let backupTaskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".backup"
    private static let maxAutoBackups = 4

    private static let excludedSettings: Set<String> = [
        AppSettings.browse.sourceLists.key, // stored separately
        AppSettings.general.icloudSync.key
    ]
    static let excludedSettingsPrefixes = [
        "Flag",
        "Data"
    ]
    static let allowedSettingsPrefixes = [
        "General",
        "Appearance",
        "Library",
        "Browse",
        "History",
        "Reader",
        "Tracker",
        "Tracking",
        "AutomaticBackups",
        "Downloads",
        "Manga",
        "Logs",
        "Search",
        "Token",
        "Dictionary"
    ]

    func save(backup: Backup, url: URL? = nil) {
        Self.directory.createDirectory()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let plist = try? encoder.encode(backup) {
            if let url = url {
                try? plist.write(to: url)
            } else {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let path = Self.directory.appendingPathComponent("aidoku_\(dateFormatter.string(from: backup.date)).aib")
                try? plist.write(to: path)
            }
            NotificationCenter.default.post(name: .updateBackupList, object: nil)
        }
    }

    func saveNewBackup(name: String = "", options: BackupOptions) async {
        save(backup: await createBackup(name: name, options: options))
    }

    func importBackup(from url: URL) -> Bool {
        Self.directory.createDirectory()
        var targetLocation = Self.directory.appendingPathComponent(url.lastPathComponent)
        while targetLocation.exists {
            targetLocation = targetLocation.deletingLastPathComponent().appendingPathComponent(
                targetLocation.deletingPathExtension().lastPathComponent.appending("_1")
            ).appendingPathExtension(url.pathExtension)
        }
        let secured = url.startAccessingSecurityScopedResource()
        defer {
            if secured {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try FileManager.default.copyItem(at: url, to: targetLocation)
            NotificationCenter.default.post(name: .updateBackupList, object: nil)
            return true
        } catch {
            return false
        }
    }

    struct BackupOptions {
        var automatic: Bool = false
        let libraryEntries: Bool
        let history: Bool
        let chapters: Bool
        let tracking: Bool
        let readingSessions: Bool
        let vocabulary: Bool
        let updates: Bool
        let categories: Bool
        let settings: Bool
        let sourceLists: Bool
        let sensitiveSettings: Bool
    }

    func createBackup(name: String = "", options: BackupOptions) async -> Backup {
        let sourceLists: [String] = if options.sourceLists {
            await SourceManager.shared.getSourceListURLs().map { $0.absoluteString }
        } else {
            []
        }
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            self.makeBackup(context: context, options: options, sourceLists: sourceLists, name: name)
        }
    }

    /// Reads from `context` everything `options` asks for and converts it into the backup's models, entity by
    /// entity. Call it on the context's queue (createBackup runs it inside `performBackgroundTask`).
    nonisolated func makeBackup(
        context: NSManagedObjectContext,
        options: BackupOptions,
        sourceLists: [String],
        name: String
    ) -> Backup {
        let library: [BackupLibraryManga] = if options.libraryEntries {
            Self.backupLibrary(CoreDataManager.shared.getLibraryManga(context: context), categories: options.categories)
        } else {
            []
        }
        let history: [BackupHistory] = if options.history {
            Self.backupHistory(CoreDataManager.shared.getHistory(context: context))
        } else {
            []
        }
        let manga: [BackupManga] = if options.libraryEntries {
            Self.backupManga(CoreDataManager.shared.getManga(context: context))
        } else {
            []
        }
        let chapters: [BackupChapter] = if options.chapters {
            Self.backupChapters(CoreDataManager.shared.getChapters(context: context))
        } else {
            []
        }
        let trackItems: [BackupTrackItem] = if options.tracking {
            Self.backupTracks(CoreDataManager.shared.getTracks(context: context))
        } else {
            []
        }
        let sessionItems: [BackupReadingSession] = if options.readingSessions {
            Self.backupSessions(CoreDataManager.shared.getSessions(context: context))
        } else {
            []
        }
        let vocabulary: [BackupVocabEntry] = if options.vocabulary {
            Self.backupVocabulary(CoreDataManager.shared.getVocab(context: context))
        } else {
            []
        }
        let updateItems: [BackupUpdate] = if options.updates {
            Self.backupUpdates(CoreDataManager.shared.getUpdates(context: context))
        } else {
            []
        }
        let categories: [BackupCategory] = if options.categories {
            Self.backupCategories(CoreDataManager.shared.getCategories(context: context))
        } else {
            []
        }
        let sources: [BackupSource] = Self.backupSources(CoreDataManager.shared.getSources(context: context))

        let settings: [String: JSONAnyValue]? = if options.settings {
            self.exportSettings(includeSensitive: options.sensitiveSettings, sourceKeys: sources.map(\.id))
        } else {
            nil
        }

        return Backup(
            library: library,
            history: history,
            manga: manga,
            chapters: chapters,
            trackItems: trackItems,
            readingSessions: sessionItems,
            vocabulary: vocabulary,
            updates: updateItems,
            categories: categories,
            sources: sources,
            sourceLists: sourceLists,
            settings: settings,
            date: Date.now,
            name: name.isEmpty ? nil : name,
            automatic: options.automatic,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        )
    }

    private nonisolated func exportSettings(includeSensitive: Bool, sourceKeys: [String]) -> [String: JSONAnyValue] {
        var allSettings = UserDefaults.standard.dictionaryRepresentation()

        // filter out potentially sensitive info
        if !includeSensitive {
            let sensitiveKeywords = ["login", "password", "token", "auth", "cookie"]
            for key in allSettings.keys where sensitiveKeywords.contains(where: key.lowercased().contains) {
                allSettings.removeValue(forKey: key)
            }
        }

        var convertedSettings: [String: JSONAnyValue] = [:]

        // convert to export compatible types
        for (key, value) in allSettings {
            guard
                Self.allowedSettingsPrefixes.contains(where: { key.hasPrefix($0) }) || sourceKeys.contains(where: { key.hasPrefix($0) }),
                !Self.excludedSettings.contains(key)
            else {
                continue
            }
            if let data = value as? Data {
                convertedSettings[key] = .data(data)
            } else if
                let number = value as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            {
                convertedSettings[key] = .bool(number.boolValue)
            } else if let value = value as? String {
                convertedSettings[key] = .string(value)
            } else if let value = value as? Int {
                convertedSettings[key] = .int(value)
            } else if let value = value as? Double {
                convertedSettings[key] = .double(value)
            } else if let value = value as? Bool {
                convertedSettings[key] = .bool(value)
            } else if let value = value as? [String] {
                convertedSettings[key] = .array(value)
            }
        }

        return convertedSettings
    }

    func renameBackup(url: URL, name: String?) -> Bool {
        guard var backup = Backup.load(from: url) else { return false }
        backup.name = name?.isEmpty ?? true ? nil : name
        save(backup: backup, url: url)
        return true
    }

    func removeBackup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: Converting
// One function per entity, called by makeBackup on the context's queue with the objects it has just fetched.
//
// Another context can delete an object (and save) between makeBackup's fetch and its conversion: the automatic
// backup runs while the app keeps working. The fetched object is then a fault that can no longer be fulfilled, Core
// Data makes it a deleted object with nil attributes (`shouldDeleteInaccessibleFaults`), and reading one of its
// non-optional attributes (`lastOpened: Date`, `sourceId: String`…) stops the app. Each conversion therefore skips
// every object that can no longer be read (and the entries whose related manga or history can no longer be read):
// it is not in the backup, as if it had been deleted before the backup started, and the log says how many.
extension BackupManager {
    nonisolated static func backupLibrary(_ objects: [LibraryMangaObject], categories: Bool) -> [BackupLibraryManga] {
        // the categories are read from the store during the conversion, after the check
        convert(objects, entity: "library entries", related: { $0.manga }, recheckInStore: categories) {
            BackupLibraryManga(libraryObject: $0, skipCategories: !categories)
        }
    }

    nonisolated static func backupHistory(_ objects: [HistoryObject]) -> [BackupHistory] {
        convert(objects, entity: "history entries") { BackupHistory(historyObject: $0) }
    }

    nonisolated static func backupManga(_ objects: [MangaObject]) -> [BackupManga] {
        convert(objects, entity: "manga") { BackupManga(mangaObject: $0) }
    }

    nonisolated static func backupChapters(_ objects: [ChapterObject]) -> [BackupChapter] {
        convert(objects, entity: "chapters") { BackupChapter(chapterObject: $0) }
    }

    nonisolated static func backupTracks(_ objects: [TrackObject]) -> [BackupTrackItem] {
        convert(objects, entity: "track items") { BackupTrackItem(trackObject: $0) }
    }

    nonisolated static func backupSessions(_ objects: [ReadingSessionObject]) -> [BackupReadingSession] {
        convert(objects, entity: "reading sessions", related: { $0.history }) { BackupReadingSession($0) }
    }

    nonisolated static func backupVocabulary(_ objects: [VocabObject]) -> [BackupVocabEntry] {
        convert(objects, entity: "vocabulary entries") { BackupVocabEntry($0) }
    }

    nonisolated static func backupUpdates(_ objects: [MangaUpdateObject]) -> [BackupUpdate] {
        convert(objects, entity: "updates") { BackupUpdate($0) }
    }

    nonisolated static func backupCategories(_ objects: [CategoryObject]) -> [BackupCategory] {
        convert(objects, entity: "categories") { BackupCategory($0) }
    }

    nonisolated static func backupSources(_ objects: [SourceObject]) -> [BackupSource] {
        convert(objects, entity: "sources") { BackupSource($0) }
    }

    /// Which of `ids` still have their row in the store (a fetch reads the store, not the context's objects), in
    /// batches under the predicate limit; nil if the store cannot be read, and then nothing is left out.
    private nonisolated static func idsInStore(_ ids: [NSManagedObjectID], context: NSManagedObjectContext) -> Set<NSManagedObjectID>? {
        guard let entityName = ids.first?.entity.name else { return [] }
        let batchSize = 500
        var existing = Set<NSManagedObjectID>()
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: entityName)
            request.resultType = .managedObjectIDResultType
            request.predicate = NSPredicate(format: "SELF IN %@", Array(ids[start..<min(start + batchSize, ids.count)]))
            do {
                existing.formUnion(try context.fetch(request))
            } catch {
                LogManager.logger.warn("Backup: could not recheck the \(entityName) objects: \(error)")
                return nil
            }
        }
        return existing
    }

    /// Whether `object` can still be read on its context's queue. A fault is fired here: either its row is loaded
    /// into the object (what the conversion reads next comes from it, not from the store) or the row is gone and
    /// Core Data marks the object as deleted.
    nonisolated static func isReadable(_ object: NSManagedObject) -> Bool {
        guard !object.isDeleted, object.managedObjectContext != nil else { return false }
        if object.isFault {
            object.willAccessValue(forKey: nil)
            object.didAccessValue(forKey: nil)
        }
        return !object.isDeleted && !object.isFault
    }

    /// `transform` of every readable object (and whose `related` object, if it has one, is readable too), in the
    /// same order; a nil from `transform` is left out as before. With `recheckInStore` (a `transform` that reads more
    /// from the store, such as a to-many relationship), the objects whose rows another context deleted while they
    /// were being converted are left out too: what `transform` read from the store after the check may no longer
    /// be theirs. Logs one line with the number of objects skipped because they could no longer be read, without any
    /// of their data.
    private nonisolated static func convert<Object: NSManagedObject, Item>(
        _ objects: [Object],
        entity: String,
        related: ((Object) -> NSManagedObject?)? = nil,
        recheckInStore: Bool = false,
        _ transform: (Object) -> Item?
    ) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(objects.count)
        var ids: [NSManagedObjectID] = []
        var context: NSManagedObjectContext?
        var skipped = 0
        for object in objects {
            guard isReadable(object) else {
                skipped += 1
                continue
            }
            if let relatedObject = related?(object), !isReadable(relatedObject) {
                skipped += 1
                continue
            }
            if let item = transform(object) {
                items.append(item)
                ids.append(object.objectID)
                context = context ?? object.managedObjectContext
            }
        }
        if
            recheckInStore,
            let context,
            let existing = idsInStore(ids, context: context)
        {
            let converted = items.count
            items = zip(ids, items).filter { existing.contains($0.0) }.map { $0.1 }
            skipped += converted - items.count
        }
        if skipped > 0 {
            LogManager.logger.warn("Backup: skipped \(skipped) \(entity) that could no longer be read")
        }
        return items
    }
}

// MARK: Restoring
extension BackupManager {
    enum BackupError: Error {
        case manga
        case categories
        case library
        case history
        case chapters
        case sessions
        case vocabulary
        case updates
        case track
        case sources

        var stringValue: String {
            switch self {
                case .manga: NSLocalizedString("CONTENT")
                case .categories: NSLocalizedString("CATEGORIES")
                case .library: NSLocalizedString("LIBRARY")
                case .history: NSLocalizedString("HISTORY")
                case .chapters: NSLocalizedString("CHAPTERS")
                case .sessions: NSLocalizedString("READING_SESSIONS")
                case .vocabulary: NSLocalizedString("VOCABULARY")
                case .updates: NSLocalizedString("UPDATES")
                case .track: NSLocalizedString("TRACKERS")
                case .sources: NSLocalizedString("SOURCES")
            }
        }
    }

    func restore(from url: URL) async -> Bool {
        guard let backup = Backup.load(from: url) else { return false }
        await doRestore(from: backup)
        return true
    }

    @discardableResult
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func doRestore(from backup: Backup) async -> Bool {
        await MainActor.run {
            UIApplication.shared.appDelegate?.showLoadingIndicator()
            UIApplication.shared.isIdleTimerDisabled = true
        }

        let sourceListsTask = Task {
            await SourceManager.shared.waitForSourceListsLoad()
            // restore source lists
            guard let sourceLists = backup.sourceLists else { return }
            await SourceManager.shared.clearSourceLists()
            for sourceList in sourceLists {
                guard let sourceListURL = URL(string: sourceList) else { continue }
                _ = await SourceManager.shared.addSourceList(url: sourceListURL, allowUnavailable: true)
            }
        }

        let mangaTask = Task {
            if let backupManga = backup.manga {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearManga(context: context)
                    for item in backupManga {
                        _ = item.toObject(context: context)
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.manga
                }
            }
        }
        let categoriesTask = Task {
            if let backupCategories = backup.categories {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearCategories(context: context)
                    for category in backupCategories {
                        _ = category.toObject(context: context)
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.categories
                }
            }
        }
        let libraryTask = Task {
            try await mangaTask.value
            try await categoriesTask.value
            if let backupLibrary = backup.library {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearLibrary(context: context)
                    let mangaByKey = Dictionary(
                        CoreDataManager.shared.getManga(context: context).map {
                            ($0.identifier, $0)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let categoryByTitle = Dictionary(
                        CoreDataManager.shared.getCategories(context: context).compactMap { category in
                            category.title.map { ($0, category) }
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    for libraryBackupItem in backupLibrary {
                        let libraryObject = libraryBackupItem.toObject(context: context)
                        if let manga = mangaByKey[libraryBackupItem.identifier] {
                            libraryObject.manga = manga
                            if let categories = libraryBackupItem.categories, !categories.isEmpty {
                                libraryObject.categories = NSSet(array: categories.compactMap { categoryByTitle[$0] })
                            }
                        }
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.library
                }
            }
        }
        let historyTask = Task {
            if let backupHistory = backup.history {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearHistory(context: context)
                    for item in backupHistory {
                        _ = item.toObject(context: context)
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.history
                }
            }
        }
        let chaptersTask = Task {
            try await historyTask.value // need to link chapters with history
            try await libraryTask.value // need to make sure manga objects aren't being modified
            if let backupChapters = backup.chapters {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearChapters(context: context)
                    let mangaByKey = Dictionary(
                        CoreDataManager.shared.getManga(context: context).map {
                            ($0.identifier, $0)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let historyByKey = Dictionary(
                        CoreDataManager.shared.getHistory(context: context).map {
                            ($0.identifier, $0)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    for backupChapter in backupChapters {
                        let chapter = backupChapter.toObject(context: context)
                        chapter.manga = mangaByKey[chapter.identifier.mangaIdentifier]
                        chapter.history = historyByKey[chapter.identifier]
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.chapters
                }
            }
        }
        let updatesTask = Task {
            try await chaptersTask.value // need to link updates with chapters
            if let backupUpdates = backup.updates {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearUpdates(context: context)
                    let chaptersByKey = Dictionary(
                        CoreDataManager.shared.getChapters(context: context).map {
                            ($0.identifier, $0)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    for backupUpdate in backupUpdates {
                        let update = backupUpdate.toObject(context: context)
                        update.chapter = chaptersByKey[update.identifier]
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.updates
                }
            }
        }
        let sessionsTask = Task {
            try await chaptersTask.value // need to link sessions with history, after being updated by chapters
            if let backupSessions = backup.readingSessions {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearSessions(context: context)
                    let historyByKey = Dictionary(
                        CoreDataManager.shared.getHistory(context: context).map {
                            ($0.identifier, $0)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    for backupSession in backupSessions {
                        // ensure data is valid
                        guard backupSession.endDate > backupSession.startDate && backupSession.pagesRead > 0 else {
                            continue
                        }
                        let session = backupSession.toObject(context: context)
                        session.history = historyByKey[backupSession.identifier]
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.sessions
                }
            }
        }
        let vocabTask = Task {
            if let vocabItems = backup.vocabulary {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearVocab(context: context)
                    for item in vocabItems {
                        _ = item.toObject(context: context)
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.vocabulary
                }
            }
        }
        let trackTask = Task {
            if let backupTrackItems = backup.trackItems {
                let result = await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearTracks(context: context)
                    for item in backupTrackItems {
                        _ = item.toObject(context: context)
                    }
                    do {
                        try context.save()
                        return true
                    } catch {
                        return false
                    }
                }
                if !result {
                    throw BackupError.track
                }
            }
        }
        let sourceTask = Task {
            await sourceListsTask.value
            if let sourceItems = backup.sources {
                let (result, needsRefresh) = await CoreDataManager.shared.container.performBackgroundTask { context in
                    var needsRefresh = false
                    for item in sourceItems {
                        guard item.config != nil else { continue }
                        CoreDataManager.shared.removeSource(key: item.id, context: context)
                        _ = item.toObject(context: context)
                        needsRefresh = true
                    }
                    do {
                        try context.save()
                        return (true, needsRefresh)
                    } catch {
                        return (false, false)
                    }
                }
                if !result {
                    throw BackupError.sources
                }
                if needsRefresh {
                    await SourceManager.shared.reloadSources()
                }
            }
        }

        var backupError: Error?

        // wait for db changes to finish
        do {
            try await updatesTask.value
            try await sessionsTask.value
            try await vocabTask.value
            try await trackTask.value
            try await sourceTask.value
        } catch {
            backupError = error
        }

        // Restore application and currently installed source settings as part of the initial restore.
        await restoreSettings(from: backup)

        await Task { @MainActor in
            await UIApplication.shared.appDelegate?.hideLoadingIndicator()
            UIApplication.shared.isIdleTimerDisabled = false
        }.value

        if backupError == nil {
            let externalSourceKeys = Set((backup.sources ?? []).lazy.filter { $0.config == nil }.map(\.id))
            let missingSourceKeys = await SourceManager.shared.missingExternalSourceKeys(in: externalSourceKeys)

            if
                !missingSourceKeys.isEmpty,
                Reachability.getConnectionType() != .none,
                await confirmExternalSourceRestore(keys: missingSourceKeys)
            {
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = true
                    UIApplication.shared.appDelegate?.showLoadingIndicator(
                        style: .progress,
                        message: NSLocalizedString("INSTALLING_SOURCES")
                    )
                }

                var installedSourceKeys: Set<String> = []

                if let (installedSourceKeyStream, total) = await SourceManager.shared.installExternalSources(keys: missingSourceKeys) {
                    var current = 0
                    for await key in installedSourceKeyStream {
                        current += 1
                        installedSourceKeys.insert(key)
                        await UIApplication.shared.appDelegate?.updateLoadingIndicator(
                            progress: Float(current - 1) / Float(total)
                        )
                    }
                }

                await restoreSettings(from: backup, sourceKeys: installedSourceKeys)

                await Task { @MainActor in
                    let appDelegate = UIApplication.shared.appDelegate
                    appDelegate?.updateLoadingIndicator(progress: 1)
                    await appDelegate?.hideLoadingIndicator()
                    UIApplication.shared.isIdleTimerDisabled = false
                }.value
            }
        }

        NotificationCenter.default.post(name: .updateHistory, object: nil)
        NotificationCenter.default.post(name: .updateTrackers, object: nil)
        NotificationCenter.default.post(name: .updateCategories, object: nil)
        NotificationCenter.default.post(name: .updateLibrary, object: nil)

        let backupSourceKeys = backup.sources?.map { $0.id } ?? []
        let missingSourceKeys = await SourceManager.shared.missingExternalSourceKeys(in: Set(backupSourceKeys))

        await Task { @MainActor [backupError] in
            let delegate = UIApplication.shared.appDelegate
            if let backupError {
                // show error alert
                delegate?.presentAlert(
                    title: NSLocalizedString("BACKUP_ERROR"),
                    message: String(
                        format: NSLocalizedString("BACKUP_ERROR_TEXT"),
                        (backupError as? BackupError)?.stringValue ?? NSLocalizedString("UNKNOWN")
                    )
                )
            } else {
                // show missing sources alert if there are any
                if !missingSourceKeys.isEmpty {
                    delegate?.presentAlert(
                        title: NSLocalizedString("MISSING_SOURCES"),
                        message: NSLocalizedString("MISSING_SOURCES_TEXT") + missingSourceKeys.map { "\n\($0)" }.joined()
                    )
                }
            }
        }.value

        return backupError == nil
    }

    private func restoreSettings(from backup: Backup, sourceKeys: Set<String>? = nil) async {
        guard let settings = backup.settings else { return }

        let sourceKeyPrefixes: [String]
        if let sourceKeys {
            sourceKeyPrefixes = sourceKeys.map { "\($0)." }
        } else {
            // only restore source settings for sources installed, or built-in sources that will be added from the backup restore
            let sources = await SourceManager.shared.getSourceInfos(sorted: false)
            sourceKeyPrefixes = sources.map { "\($0.sourceId)." } + (backup.sources ?? []).compactMap {
                $0.config == nil ? nil : "\($0.id)."
            }
        }

        let written = Self.applySettings(
            settings.mapValues { $0.toRaw() },
            sourceKeyPrefixes: sourceKeyPrefixes,
            onlySources: sourceKeys != nil
        )

        if !written.isDisjoint(with: AppDelegate.legacySettingKeys) {
            await MainActor.run {
                UIApplication.shared.appDelegate?.migrateSettings()
            }
        }
    }

    /// Writes the backup settings that may be restored and returns their keys. Then migrates the pillarbox
    /// margins if an old backup brought the old pillarbox keys.
    /// - onlySources: only settings of the given sources (restoring missing sources afterwards).
    @discardableResult
    nonisolated static func applySettings(
        _ settings: [String: Any?],
        sourceKeyPrefixes: [String],
        onlySources: Bool,
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) -> Set<String> {
        var written = Set<String>()
        for (key, value) in settings {
            let hasAllowedPrefix = (!onlySources && allowedSettingsPrefixes.contains { key.hasPrefix($0) })
                || sourceKeyPrefixes.contains { key.hasPrefix($0) }
            guard
                hasAllowedPrefix,
                !excludedSettings.contains(key),
                !excludedSettingsPrefixes.contains(where: { key.hasPrefix($0) })
            else {
                continue
            }
            defaults.set(value ?? nil, forKey: key)
            written.insert(key)
        }
        // a backup from before the pillarbox margin per orientation (only keys really restored count)
        PillarboxSettings.restoredFromBackup(keys: written, defaults: defaults, domain: domain)
        return written
    }

    private func confirmExternalSourceRestore(keys: Set<String>) async -> Bool {
        let message = NSLocalizedString("RESTORE_MISSING_SOURCES_TEXT") + keys.sorted().map { "\n\($0)" }.joined()

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard
                    let delegate = UIApplication.shared.appDelegate,
                    delegate.topViewController != nil
                else {
                    continuation.resume(returning: false)
                    return
                }
                delegate.presentAlert(
                    title: NSLocalizedString("RESTORE_MISSING_SOURCES"),
                    message: message,
                    actions: [
                        UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel) { _ in
                            continuation.resume(returning: false)
                        },
                        UIAlertAction(title: NSLocalizedString("INSTALL_SOURCES"), style: .default) { _ in
                            continuation.resume(returning: true)
                        }
                    ]
                )
            }
        }
    }
}

// MARK: Automatic Backups
extension BackupManager {
    nonisolated func register() {
#if !targetEnvironment(simulator)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backupTaskIdentifier, using: nil) { @Sendable [weak self] task in
            guard let self, let task = task as? BGProcessingTask else { return }

            Task { @Sendable in
                await self.createAutoBackup()

                task.setTaskCompleted(success: true)
            }
        }
#endif
    }

    func scheduleAutoBackup() {
        guard AppSettings.backups.autoBackups.enabled.get() else {
#if !targetEnvironment(simulator)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backupTaskIdentifier)
#endif
            return
        }

        let lastUpdated = AppSettings.backups.autoBackups.lastBackup.get()
        let interval: Double = switch AppSettings.backups.autoBackups.interval.get() {
            case "6hours": 21600
            case "12hours": 43200
            case "daily": 86400
            case "2days": 172800
            case "weekly": 604800
            default: 0
        }
        let nextUpdateTime = lastUpdated + interval

        if nextUpdateTime < Date.now {
            // interval time has passed, create auto backup now
            Task {
                await createAutoBackup()
            }
        } else {
#if !targetEnvironment(simulator)
            // schedule task for the future
            let request = BGProcessingTaskRequest(identifier: Self.backupTaskIdentifier)
            request.earliestBeginDate = nextUpdateTime
            request.requiresExternalPower = false
            request.requiresNetworkConnectivity = false

            Task {
                do {
                    try await BGTaskScheduler.shared.submit(request: request)
                } catch {
                    LogManager.logger.error("Could not schedule automatic backup: \(error)")
                }
            }
#endif
        }
    }

    private func createAutoBackup() async {
        guard AppSettings.backups.autoBackups.enabled.get() else { return }

        let libraryEntries = AppSettings.backups.autoBackups.libraryEntries.get()
        let history = AppSettings.backups.autoBackups.history.get()
        let chapters = AppSettings.backups.autoBackups.chapters.get()
        let tracking = AppSettings.backups.autoBackups.tracking.get()
        let readingSessions = AppSettings.backups.autoBackups.readingSessions.get()
        let vocabulary = AppSettings.backups.autoBackups.vocabulary.get()
        let updates = AppSettings.backups.autoBackups.updates.get()
        let categories = AppSettings.backups.autoBackups.categories.get()
        let settings = AppSettings.backups.autoBackups.settings.get()
        let sourceLists = AppSettings.backups.autoBackups.sourceLists.get()
        let sensitiveSettings = AppSettings.backups.autoBackups.sensitiveSettings.get()

        await self.saveNewBackup(
            options: .init(
                automatic: true,
                libraryEntries: libraryEntries,
                history: history,
                chapters: chapters,
                tracking: tracking,
                readingSessions: readingSessions,
                vocabulary: vocabulary,
                updates: updates,
                categories: categories,
                settings: settings,
                sourceLists: sourceLists,
                sensitiveSettings: sensitiveSettings
            )
        )

        // update last auto backup time
        AppSettings.backups.autoBackups.lastBackup.set(Date.now)

        cleanUpAutoBackups()
        scheduleAutoBackup() // schedule the next one
    }

    // ensure we keep only the latest maxAutoBackups automatic backups
    private func cleanUpAutoBackups() {
        var autoBackups: [BackupInfo] = []
        for backupUrl in Self.backupUrls {
            let backup = BackupInfo.load(from: backupUrl)
            if let backup, backup.automatic {
                autoBackups.append(backup)
            }
        }
        while autoBackups.count > Self.maxAutoBackups {
            let oldestBackup = autoBackups
                .min { $0.date < $1.date }
            if let oldestBackup {
                removeBackup(url: oldestBackup.url)
                autoBackups.removeAll { $0.url == oldestBackup.url }
            } else {
                break
            }
        }
    }
}
