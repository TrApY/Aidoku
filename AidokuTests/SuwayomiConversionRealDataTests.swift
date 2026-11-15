//
//  SuwayomiConversionRealDataTests.swift
//  AidokuTests
//
//  SUWA-12 T6: the conversion on a COPY of a real store (never the original; nothing of it goes to the
//  repo). Runs only with SUWA12_COPIA = a folder with <device>/Library/Application Support/*.sqlite,
//  <device>/Library/Preferences/<bundle>.plist, <device>/Documents/Downloads and mapa-fuentes.json
//  (manga id → server source id, asked to the real server). The figures go to SUWA12_OUT, without titles.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

private let copyFolder = ProcessInfo.processInfo.environment["SUWA12_COPIA"].map { URL(fileURLWithPath: $0) }

@Suite(.serialized) struct SuwayomiConversionRealDataTests {
    private struct MangaState: Equatable {
        var chapters = 0
        var completed: [String: TimeInterval] = [:] // chapter id → read date
        var unfinished: [String: String] = [:] // chapter id → page/total/position/date
        var categories: [String] = []
        var tracks: [String] = []
        var updates = 0
        var vocab = 0
        var settings: [String: String] = [:] // prefix → value
        var downloads: [String] = []
    }

    @Test(.enabled(if: copyFolder != nil), arguments: ["iphone", "ipad"])
    func theRealLibraryIsConvertedWithoutLosingAnything(device: String) async throws {
        let folder = try #require(copyFolder).appendingPathComponent(device)
        let supportFolder = folder.appendingPathComponent("Library/Application Support")
        try #require(FileManager.default.fileExists(atPath: supportFolder.appendingPathComponent("Aidoku.sqlite").path))
        let store = try ConversionStore(copyFrom: supportFolder)
        defer { store.close() }

        // settings of the copy (no passwords nor tokens: not needed), downloads of the copy
        let plist = folder.appendingPathComponent("Library/Preferences/dev.alexmarin.aidoku.plist")
        if let dict = NSDictionary(contentsOf: plist) as? [String: Any] {
            let safe = dict.filter { key, _ in !["password", "token", "cookie", "username"].contains { key.localizedCaseInsensitiveContains($0) } }
            store.defaults.setPersistentDomain(safe, forName: store.domain)
        }
        let downloads = folder.appendingPathComponent("Documents/Downloads")
        if FileManager.default.fileExists(atPath: downloads.path) {
            try FileManager.default.removeItem(at: store.downloads)
            try FileManager.default.copyItem(at: downloads, to: store.downloads)
        }

        let mapUrl = try #require(copyFolder).appendingPathComponent("mapa-fuentes.json")
        let map = try #require(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: mapUrl)) as? [String: Any])?["mapa"] as? [String: String]
        )
        let parents = connections(store)
        try #require(!parents.isEmpty)
        let children = parents.flatMap { parent in
            Set(map.values).map { id in
                SuwayomiServerSourceConfig(
                    key: "\(parent).\(id)", parentKey: parent, serverSourceId: id, name: id, lang: "es",
                    iconUrl: "", isNsfw: false, supportsLatest: true, available: true
                )
            }
        }

        var before: [String: MangaState] = [:] // "<parent>|<id>"
        for parent in parents {
            for id in await SuwayomiSourceConversion.mangaIds(under: parent, env: store.environment(resolve: { _, _ in [:] }, children: [])) {
                before["\(parent)|\(id)"] = state(store, sourceId: parent, mangaId: id)
            }
        }
        let report = await SuwayomiSourceConversion.run(
            parentKeys: parents,
            environment: store.environment(resolve: { _, ids in map.filter { ids.contains($0.key) } }, children: children)
        )

        var equal = 0
        var different: [String] = []
        var totals = (chapters: 0, completed: 0, unfinished: 0, downloads: 0)
        for (key, old) in before {
            let parts = key.split(separator: "|").map(String.init)
            let (parent, id) = (parts[0], parts[1])
            let newKey = map[id].map { "\(parent).\($0)" } ?? parent
            let new = state(store, sourceId: newKey, mangaId: id)
            if new == old {
                equal += 1
            } else {
                different.append(id)
            }
            #expect(new == old, "manga \(id)")
            totals.chapters += old.chapters
            totals.completed += old.completed.count
            totals.unfinished += old.unfinished.count
            totals.downloads += old.downloads.count
        }
        let leftUnderParent = parents.map { parent in
            SuwayomiSourceConversion.entities.map { store.count($0, sourceId: parent) }.reduce(0, +)
        }.reduce(0, +)
        #expect(report.failed == 0)
        #expect(report.converted + report.pending == before.count)

        if let out = ProcessInfo.processInfo.environment["SUWA12_OUT"] {
            let line = "\(device): mangas=\(before.count) convertidos=\(report.converted) pendientes=\(report.pending) "
                + "fallidos=\(report.failed) fusionadas=\(report.merged) iguales=\(equal) distintos=\(different.count) "
                + "capitulos=\(totals.chapters) historial-completado=\(totals.completed) a-medias=\(totals.unfinished) "
                + "descargas=\(totals.downloads) filas-bajo-padre=\(leftUnderParent) conexiones=\(parents.count)\n"
            if let handle = FileHandle(forWritingAtPath: out) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: out, contents: Data(line.utf8))
            }
        }
    }

    private func connections(_ store: ConversionStore) -> [String] {
        let context = store.container.newBackgroundContext()
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Source")
            return ((try? context.fetch(request)) ?? []).compactMap { object in
                guard
                    let data = object.value(forKey: "customSource") as? Data,
                    case let .suwayomi(config)? = try? CustomSourceConfig(from: data)
                else { return nil }
                return config.key
            }
        }
    }

    private func state(_ store: ConversionStore, sourceId: String, mangaId: String) -> MangaState {
        let context = store.container.newBackgroundContext()
        var result = context.performAndWait {
            var state = MangaState()
            func fetch(_ entity: String) -> [NSManagedObject] {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "sourceId == %@ AND \(entity == "Manga" ? "id" : "mangaId") == %@", sourceId, mangaId)
                return (try? context.fetch(request)) ?? []
            }
            state.chapters = fetch("Chapter").count
            for history in fetch("History") {
                let chapter = history.value(forKey: "chapterId") as? String ?? ""
                let date = (history.value(forKey: "dateRead") as? Date)?.timeIntervalSince1970 ?? 0
                if history.value(forKey: "completed") as? Bool == true {
                    state.completed[chapter] = date
                } else {
                    state.unfinished[chapter] = "\(history.value(forKey: "progress") ?? 0)/\(history.value(forKey: "total") ?? 0)"
                        + "/\(history.value(forKey: "scrollPosition") ?? 0)/\(date)/\((history.value(forKey: "sessions") as? Set<NSManagedObject>)?.count ?? 0)"
                }
            }
            if let library = fetch("Manga").first?.value(forKey: "libraryObject") as? NSManagedObject {
                state.categories = ((library.value(forKey: "categories") as? Set<NSManagedObject>) ?? [])
                    .compactMap { $0.value(forKey: "title") as? String }.sorted()
            }
            state.tracks = fetch("Track").map { "\($0.value(forKey: "trackerId") ?? "")=\($0.value(forKey: "id") ?? "")" }.sorted()
            state.updates = fetch("MangaUpdate").count
            state.vocab = fetch("Vocab").count
            return state
        }
        for key in (store.defaults.persistentDomain(forName: store.domain) ?? [:]).keys {
            if let (prefix, id) = SuwayomiSourceConversion.perMangaKey(key, parent: sourceId), id == mangaId {
                result.settings[prefix] = "\(store.defaults.object(forKey: key) ?? "")"
            } else if key.hasSuffix(".\(sourceId).\(mangaId)"), !key.hasPrefix(sourceId) {
                // a child key (`<prefix>.<parent>.<server id>.<id>`)
                let prefix = String(key.dropLast(".\(sourceId).\(mangaId)".count))
                result.settings[prefix] = "\(store.defaults.object(forKey: key) ?? "")"
            }
        }
        let folder = store.downloads.appendingSafePathComponent(sourceId).appendingSafePathComponent(mangaId)
        result.downloads = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return result
    }
}
