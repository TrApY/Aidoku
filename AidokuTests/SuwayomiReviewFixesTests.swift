//
//  SuwayomiReviewFixesTests.swift
//  AidokuTests
//
//  SUWA-12 encargo C: fixes from the independent review of the conversion.
//  M1 another device (rows converted elsewhere came by iCloud, no server here), M2 the download queue
//  during the conversion, B3 merging duplicates, B4 settings rewritten only after a backup.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct SuwayomiReviewFixesTests {
    let parent = "suwayomi.revtest"
    let sourceA = "1596411039134168890"
    let date1 = Date(timeIntervalSince1970: 1_763_000_000)
    let date2 = Date(timeIntervalSince1970: 1_763_100_000)
    var childA: String { "\(parent).\(sourceA)" }

    private var children: [SuwayomiServerSourceConfig] {
        [.init(
            key: childA, parentKey: parent, serverSourceId: sourceA, name: "Olympus", lang: "es",
            iconUrl: "", isNsfw: false, supportsLatest: true, available: true
        )]
    }

    @discardableResult
    private func manga(_ store: ConversionStore, _ sourceId: String, _ id: String, _ values: [String: Any] = [:], library: [String: Any]? = nil, in context: NSManagedObjectContext) -> NSManagedObject {
        var fields: [String: Any] = [
            "sourceId": sourceId, "id": id, "title": "Manga \(id)", "neverUpdate": false, "chapterFlags": Int16(0),
            "editedKeys": Int32(0), "nsfw": Int16(0), "status": Int16(0), "viewer": Int16(0)
        ]
        fields.merge(values) { _, new in new }
        let object = store.insert("Manga", fields, in: context)
        if let library {
            var libraryFields = library
            libraryFields["manga"] = object
            store.insert("LibraryManga", libraryFields, in: context)
        }
        return object
    }

    // MARK: M1

    @Test func childrenAskedForByTheDataAreRegisteredWithoutTheServer() {
        let snapshot = [SuwayomiServerSource(
            id: sourceA, name: "Olympus Scanlation", lang: "es", displayName: "Olympus Scanlation (ES)",
            isNsfw: false, supportsLatest: true, iconUrl: "/icon/olympus.png"
        )]
        let planned = SuwayomiServerSourceSync.planFromData(
            parentKey: parent,
            sourceKeysInData: [childA, "\(parent).4562754350961964148", "\(parent).9", parent, "\(parent)-1.5", "multi.otra"],
            existing: [.init(
                key: "\(parent).9", parentKey: parent, serverSourceId: "9", name: "Ya", lang: "es",
                iconUrl: "", isNsfw: false, supportsLatest: false, available: true
            )],
            snapshot: snapshot
        )
        #expect(planned.map(\.key) == [childA, "\(parent).4562754350961964148"])
        // from the last list the server gave
        #expect(planned.first?.lang == "es")
        #expect(planned.first?.serverSourceId == sourceA)
        #expect(planned.first?.name.contains("Olympus") == true)
        // not in it: a provisional name the next sync corrects
        #expect(planned.last?.name == NSLocalizedString("SUWAYOMI_SERVER_SOURCE_PROVISIONAL"))
        #expect(planned.last?.available == true)
    }

    @Test func rowsConvertedOnAnotherDeviceTakeTheDownloadsAndSettingsHereWithoutTheServer() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        // 101 came by iCloud already under its server source; 104 is still under the parent
        let context = store.container.newBackgroundContext()
        let (parent, childA, date1) = (parent, childA, date1)
        try context.performAndWait {
            manga(store, childA, "101", library: ["dateAdded": date1], in: context)
            store.insert("History", [
                "sourceId": childA, "mangaId": "101", "chapterId": "10101", "completed": true,
                "progress": Int16(0), "dateRead": date1
            ], in: context)
            manga(store, parent, "104", in: context)
            try context.save()
        }
        for id in ["101", "104"] {
            let folder = store.downloads.appendingPathComponent(parent).appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("cbz \(id)".utf8).write(to: folder.appendingPathComponent("\(id)03.cbz"))
            store.defaults.set("webtoon", forKey: "Reader.readingMode.\(parent).\(id)")
        }
        let backups = Counter()
        let report = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(
                resolve: { _, _ in throw SourceError.networkError }, // no server here
                children: children,
                backup: { backups.add(); return true }
            )
        )
        #expect(report.outcome == .serverUnavailable)
        #expect(report.converted == 1)
        #expect(report.pendingIds == [parent: ["104"]])
        let moved = store.downloads.appendingPathComponent(childA).appendingPathComponent("101/10103.cbz")
        #expect((try? String(contentsOf: moved, encoding: .utf8)) == "cbz 101")
        #expect(!FileManager.default.fileExists(atPath: store.downloads.appendingPathComponent(parent).appendingPathComponent("101").path))
        #expect(store.defaults.string(forKey: "Reader.readingMode.\(childA).101") == "webtoon")
        #expect(store.defaults.object(forKey: "Reader.readingMode.\(parent).101") == nil)
        // the one the server must place: untouched
        #expect(FileManager.default.fileExists(atPath: store.downloads.appendingPathComponent(parent).appendingPathComponent("104/10403.cbz").path))
        #expect(store.defaults.string(forKey: "Reader.readingMode.\(parent).104") == "webtoon")
        #expect(store.count("Manga", sourceId: parent) == 1)
        #expect(backups.count == 1)
    }

    @Test func aServerSourceOfAConnectionIsNotSaidToBeUninstalled() {
        let connection = "suwayomi.revtest-notice"
        SuwayomiConnections.shared.register(connection: connection)
        defer { SuwayomiConnections.shared.unregister(connection) }
        #expect(SuwayomiConnections.shared.isServerSourceOfConnection("\(connection).1596411039134168890"))
        #expect(!SuwayomiConnections.shared.isServerSourceOfConnection(connection))
        #expect(!SuwayomiConnections.shared.isServerSourceOfConnection("\(connection)-1.15"))
        #expect(!SuwayomiConnections.shared.isServerSourceOfConnection("multi.otra"))
        #expect(MangaSourceNotice.make(sourcesLoaded: true, hasSource: false, inLibrary: true, hasWebUrl: false, pendingServerSource: true) == nil)
        #expect(MangaSourceNotice.make(sourcesLoaded: true, hasSource: false, inLibrary: true, hasWebUrl: false) == .init(migrate: true, webView: false))
    }

    // MARK: M2

    @MainActor
    @Test func theQueueWaitsForTheConversionAndThenPointsToTheServerSource() async throws {
        let stateKey = "suwa12.queue.\(UUID().uuidString)"
        let queueParent = "suwayomi.revtest-queue"
        let queueChild = "\(queueParent).\(sourceA)"
        defer {
            UserDefaults.standard.removeObject(forKey: stateKey)
            for key in [queueParent, queueChild] {
                try? FileManager.default.removeItem(at: DownloadManager.directory.appendingPathComponent(key))
            }
        }
        let manga = AidokuRunner.Manga(sourceKey: queueParent, key: "101", title: "Manga 101")
        let download = Download.from(manga: manga, chapter: .init(key: "10103", chapterNumber: 3))
        UserDefaults.standard.set(try JSONEncoder().encode([queueParent: [download]]), forKey: stateKey)
        let queue = DownloadQueue(cache: DownloadCache(), stateKey: stateKey, sourceLookup: { _ in nil })

        // the user had paused it (it must stay so), and the conversion starts before the saved queue is
        // loaded (the start's wait ran out)
        await queue.pause(byUser: true)
        await queue.suspendForExternalChange()
        await queue.loadQueueState()
        #expect(await queue.taskChapterKeys(sourceKey: queueParent) == nil) // nothing downloads under the parent
        // a download asked for meanwhile doesn't start the queue either
        await queue.add(chapters: [.init(key: "10104", chapterNumber: 4)], manga: manga)
        #expect(await queue.taskChapterKeys(sourceKey: queueParent) == nil)

        // the conversion rewrites the saved queue
        let saved = try #require(UserDefaults.standard.data(forKey: stateKey))
        let rewritten = SuwayomiSourceConversion.rewriteQueue(
            try JSONSerialization.jsonObject(with: saved),
            moved: [queueParent: ["101": queueChild]]
        )
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: rewritten), forKey: stateKey)
        await queue.resumeAfterExternalChange()

        let keys = await queue.queue.keys.sorted()
        #expect(keys == [queueChild])
        #expect(await queue.queue[queueChild]?.map(\.chapterIdentifier.chapterKey).sorted() == ["10103", "10104"])
        #expect(await queue.taskChapterKeys(sourceKey: queueParent) == nil)
        #expect(await queue.isPausedByUser())
        await queue.cancelAll()
    }

    // MARK: B3

    @Test func mergingKeepsWhatWasSetAndTheLibraryDates() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        let context = store.container.newBackgroundContext()
        let (parent, childA, date1, date2) = (parent, childA, date1, date2)
        try context.performAndWait {
            // already under the server source (iCloud): defaults, added later, read earlier
            manga(store, childA, "101", ["title": "Nuevo"], library: [
                "dateAdded": date2, "lastRead": date1, "lastOpened": date1
            ], in: context)
            // the old one, under the parent: set by the user, added earlier, read later
            manga(store, parent, "101", [
                "title": "Viejo", "viewer": Int16(2), "chapterFlags": Int16(3), "langFilter": "es", "neverUpdate": true
            ], library: ["dateAdded": date1, "lastRead": date2, "lastOpened": date2], in: context)
            try context.save()
        }
        let report = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(resolve: { _, _ in ["101": sourceA] }, children: children)
        )
        #expect(report.converted == 1)
        #expect(report.merged == 1)
        let reader = store.container.newBackgroundContext() // not the one that inserted (it caches the rows)
        let values: [String: String] = reader.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Manga")
            request.predicate = NSPredicate(format: "sourceId == %@ AND id == %@", childA, "101")
            guard let kept = try? reader.fetch(request).first else { return [:] }
            let library = kept.value(forKey: "libraryObject") as? NSManagedObject
            return [
                "title": "\(kept.value(forKey: "title") ?? "")",
                "viewer": "\(kept.value(forKey: "viewer") ?? "")",
                "chapterFlags": "\(kept.value(forKey: "chapterFlags") ?? "")",
                "langFilter": "\(kept.value(forKey: "langFilter") ?? "")",
                "neverUpdate": "\(kept.value(forKey: "neverUpdate") ?? "")",
                "dateAdded": "\((library?.value(forKey: "dateAdded") as? Date)?.timeIntervalSince1970 ?? 0)",
                "lastRead": "\((library?.value(forKey: "lastRead") as? Date)?.timeIntervalSince1970 ?? 0)",
                "lastOpened": "\((library?.value(forKey: "lastOpened") as? Date)?.timeIntervalSince1970 ?? 0)"
            ]
        }
        #expect(values["title"] == "Nuevo") // both set: the kept row's
        #expect(values["viewer"] == "2")
        #expect(values["chapterFlags"] == "3")
        #expect(values["langFilter"] == "es")
        #expect(values["neverUpdate"] == "1")
        #expect(values["dateAdded"] == "\(date1.timeIntervalSince1970)") // the earliest
        #expect(values["lastRead"] == "\(date2.timeIntervalSince1970)") // the latest
        #expect(values["lastOpened"] == "\(date2.timeIntervalSince1970)")
    }

    // MARK: B4

    @Test func settingsAreOnlyRewrittenAfterABackup() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        // nothing to convert, but the parent is pinned
        store.defaults.set([parent, "multi.otra"], forKey: AppSettings.browse.pinnedList.key)
        let failed = await SuwayomiSourceConversion.run(
            parentKeys: [parent],
            environment: store.environment(resolve: { _, _ in [:] }, children: children, backup: { false })
        )
        #expect(failed.outcome == .nothingToConvert)
        #expect(store.defaults.stringArray(forKey: AppSettings.browse.pinnedList.key) == [parent, "multi.otra"])

        let backups = Counter()
        let env = store.environment(resolve: { _, _ in [:] }, children: children, backup: { backups.add(); return true })
        _ = await SuwayomiSourceConversion.run(parentKeys: [parent], environment: env)
        #expect(store.defaults.stringArray(forKey: AppSettings.browse.pinnedList.key) == ["multi.otra"])
        #expect(backups.count == 1)
        // nothing changes now: no backup, no write
        _ = await SuwayomiSourceConversion.run(parentKeys: [parent], environment: env)
        #expect(backups.count == 1)
    }
}
