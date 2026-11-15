//
//  SuwayomiStartup.swift
//  Aidoku
//
//  At start, after loading the sources and BEFORE resuming the download queue and the scheduled backup:
//  the server sources are synced (D4) and what is still under a Suwayomi connection is converted (D6).
//  Also from «Reintentar» in Ajustes › Servidor Suwayomi.
//

import AidokuRunner
import CoreData
import Foundation

actor SuwayomiStartup {
    static let shared = SuwayomiStartup()

    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var running: Task<SuwayomiSourceConversion.Report, Never>?
    private(set) var lastReport: SuwayomiSourceConversion.Report?

    /// The start work; once (later calls wait for the first).
    func run() async {
        guard !finished, running == nil else {
            await waitUntilFinished()
            return
        }
        _ = await convert()
        finish()
    }

    /// Sync and conversion now («Reintentar»; also at start).
    @discardableResult
    func convert() async -> SuwayomiSourceConversion.Report {
        if let running {
            return await running.value
        }
        let task = Task<SuwayomiSourceConversion.Report, Never> {
            await SuwayomiServerSourceSync.syncAll()
            let parents = await Self.connectionKeys()
            return await SuwayomiSourceConversion.run(parentKeys: parents, environment: Self.appEnvironment())
        }
        running = task
        let report = await task.value
        running = nil
        lastReport = report
        if report.converted > 0 {
            await TrackerManager.shared.reloadPageTrackingState()
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
            NotificationCenter.default.post(name: .updateHistory, object: nil)
        }
        return report
    }

    /// Waits for the start work (the download queue waits for it), at most `timeout` seconds.
    func waitUntilFinished(timeout: TimeInterval = 90) async {
        guard !finished else { return }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self.finish()
        }
        await withCheckedContinuation { waiters.append($0) }
        deadline.cancel()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    /// Manga still under each connection (Ajustes › Servidor Suwayomi).
    static func pendingCount() async -> Int {
        let env = appEnvironment()
        var count = 0
        for parent in await connectionKeys() {
            count += await SuwayomiSourceConversion.mangaIds(under: parent, env: env).count
        }
        return count
    }

    static func connectionKeys() async -> [String] {
        await SourceManager.shared.customSourceConfigs().compactMap { config in
            if case let .suwayomi(values) = config { return values.key }
            return nil
        }
    }

    static func appEnvironment() -> SuwayomiSourceConversion.Environment {
        .init(
            container: CoreDataManager.shared.container,
            defaults: .standard,
            defaultsDomain: Bundle.main.bundleIdentifier ?? "",
            downloadsDirectory: DownloadManager.directory,
            resolve: { parent, ids in
                try await resolveServerSources(helper: SuwayomiHelper(sourceKey: parent), mangaIds: ids)
            },
            children: { parent in
                await SourceManager.shared.customSourceConfigs().compactMap { config in
                    if case let .suwayomiServerSource(values) = config, values.parentKey == parent { return values }
                    return nil
                }
            },
            backup: { await saveBackupBeforeConversion() },
            downloadsMoved: { await DownloadManager.shared.reloadAfterExternalChange() }
        )
    }

    /// «antes-SUWA-12» in Documents/Backups, with everything but the passwords.
    static func saveBackupBeforeConversion() async -> Bool {
        let backup = await BackupManager.shared.createBackup(
            name: "antes-SUWA-12",
            options: .init(
                libraryEntries: true,
                history: true,
                chapters: true,
                tracking: true,
                readingSessions: true,
                vocabulary: true,
                updates: true,
                categories: true,
                settings: true,
                sourceLists: true,
                sensitiveSettings: false
            )
        )
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = BackupManager.directory.appendingPathComponent("aidoku_\(formatter.string(from: Date()))_antes-SUWA-12.aib")
        BackupManager.directory.createDirectory()
        await BackupManager.shared.save(backup: backup, url: url)
        let saved = FileManager.default.fileExists(atPath: url.path)
        if saved {
            NotificationCenter.default.post(name: .updateBackupList, object: nil)
        }
        return saved
    }
}

// MARK: Server source of each manga
extension SuwayomiStartup {
    private struct BatchPayload: Encodable {
        let variables: Variables
        let query = """
            query GetMangaSources($ids: [Int!]!) {
              mangas(filter: {id: {in: $ids}}) {
                nodes {
                  id
                  sourceId
                }
              }
            }
            """

        struct Variables: Encodable {
            let ids: [Int]
        }
    }

    private struct BatchResponse: Decodable, Sendable {
        let data: DataContainer
        struct DataContainer: Decodable, Sendable {
            let mangas: Connection
        }
        struct Connection: Decodable, Sendable {
            let nodes: [Node]
        }
        struct Node: Decodable, Sendable {
            let id: Int
            let sourceId: String
        }
    }

    private struct OnePayload: Encodable {
        let variables: Variables
        let query = """
            query GetMangaSource($id: Int!) {
              manga(id: $id) {
                sourceId
              }
            }
            """

        struct Variables: Encodable {
            let id: Int
        }
    }

    private struct OneResponse: Decodable, Sendable {
        let data: DataContainer
        struct DataContainer: Decodable, Sendable {
            let manga: Manga
        }
        struct Manga: Decodable, Sendable {
            let sourceId: String
        }
    }

    /// The server couldn't be asked (network, login, no server), as opposed to a GraphQL answer.
    static func isConnectionFailure(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? SourceError else { return false }
        switch error {
            case .networkError:
                return true
            case let .message(message):
                return ["NOT_LOGGED_IN", "NO_SERVER_CONFIGURED", "INVALID_SERVER_URL"].contains(message)
            default:
                return false
        }
    }

    /// manga id → server source id, for the ids the server knows. In batches of 100; a server without the
    /// filter: one per manga, 4 at a time. Throws only when the server doesn't answer.
    static func resolveServerSources(helper: SuwayomiHelper, mangaIds: [String]) async throws -> [String: String] {
        let ids = mangaIds.compactMap(Int.init)
        var result: [String: String] = [:]
        do {
            for batch in ids.chunked(into: 100) {
                let response: BatchResponse = try await helper.request(
                    body: BatchPayload(variables: .init(ids: batch)),
                    timeout: SuwayomiServerSources.sourcesTimeout
                )
                for node in response.data.mangas.nodes {
                    result[String(node.id)] = node.sourceId
                }
            }
            return result
        } catch where isConnectionFailure(error) {
            throw error
        } catch {
            LogManager.logger.warn("Suwayomi batch query of manga sources failed, asking one by one: \(error)")
        }
        let answers = await withTaskGroup(of: (Int, String?, Bool).self) { group in
            var answers: [(Int, String?, Bool)] = []
            var next = 0
            func add() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask {
                    do {
                        let response: OneResponse = try await helper.request(
                            body: OnePayload(variables: .init(id: id)),
                            timeout: SuwayomiServerSources.sourcesTimeout
                        )
                        return (id, response.data.manga.sourceId, true)
                    } catch where isConnectionFailure(error) {
                        return (id, nil, false)
                    } catch {
                        return (id, nil, true) // answered: unknown manga
                    }
                }
            }
            for _ in 0..<4 { add() }
            while let answer = await group.next() {
                answers.append(answer)
                add()
            }
            return answers
        }
        guard answers.isEmpty || answers.contains(where: \.2) else {
            throw URLError(.cannotConnectToHost)
        }
        for (id, sourceId, _) in answers {
            if let sourceId {
                result[String(id)] = sourceId
            }
        }
        return result
    }
}
