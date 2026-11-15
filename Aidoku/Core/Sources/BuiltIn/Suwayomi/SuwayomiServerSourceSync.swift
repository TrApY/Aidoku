//
//  SuwayomiServerSourceSync.swift
//  Aidoku
//
//  Keeps one Aidoku source per source installed on each Suwayomi server (SUWA-12, D4): at start (after
//  loading the sources) and when the connection is saved. All the server's sources are added, without
//  marks per device. A source the server doesn't have anymore is NEVER removed (that would remove its
//  settings and tracking): it is marked unavailable (hidden from the lists, its manga keep working) and
//  comes back if the server has it again. A server that doesn't answer changes nothing.
//

import AidokuRunner
import Foundation

enum SuwayomiServerSourceSync {
    /// The configs to save so the children of `parentKey` match `server` (only new or changed ones).
    static func plan(
        parentKey: String,
        existing: [SuwayomiServerSourceConfig],
        server: [SuwayomiServerSource]
    ) -> [SuwayomiServerSourceConfig] {
        let mine = existing.filter { $0.parentKey == parentKey }
        let known = Dictionary(mine.map { ($0.serverSourceId, $0) }, uniquingKeysWith: { first, _ in first })
        let offered = server.filter { $0.id != SuwayomiServerSources.localSourceId }
        let onServer = Set(offered.map(\.id))
        var changes: [SuwayomiServerSourceConfig] = []
        for source in offered {
            // new, changed on the server, or back on it
            let config = SuwayomiServerSourceConfig(parentKey: parentKey, server: source)
            if known[source.id] != config {
                changes.append(config)
            }
        }
        for old in mine where old.available && !onServer.contains(old.serverSourceId) {
            var gone = old
            gone.available = false
            changes.append(gone)
        }
        return changes
    }

    struct Result: Equatable, Sendable {
        /// The server answered.
        var answered: Bool
        var added: Int = 0
        var updated: Int = 0
        var unavailable: Int = 0
    }

    /// Asks the server for its sources and saves what changed. `fetch` throwing (server down) = no change.
    static func sync(
        parentKey: String,
        existing: [SuwayomiServerSourceConfig],
        fetch: @Sendable () async throws -> [SuwayomiServerSource],
        prepare: @Sendable ([SuwayomiServerSourceConfig]) async -> Void = { _ in },
        save: @Sendable (SuwayomiServerSourceConfig) async -> Bool
    ) async -> Result {
        let server: [SuwayomiServerSource]
        do {
            server = try await fetch()
        } catch {
            LogManager.logger.warn("Suwayomi sources of \(parentKey) not synced, the server didn't answer: \(error)")
            return .init(answered: false)
        }
        let changes = plan(parentKey: parentKey, existing: existing, server: server)
        await prepare(changes)
        var result = Result(answered: true)
        let known = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for config in changes {
            guard await save(config) else { continue }
            if let old = known[config.key] {
                if old.available && !config.available {
                    result.unavailable += 1
                } else {
                    result.updated += 1
                }
            } else {
                result.added += 1
            }
        }
        return result
    }
}

// MARK: App wiring
extension SuwayomiServerSourceSync {
    /// Syncs every Suwayomi connection installed (start, connection saved).
    static func syncAll() async {
        let configs = await SourceManager.shared.customSourceConfigs()
        let parents = configs.compactMap { config -> String? in
            if case let .suwayomi(values) = config { return values.key }
            return nil
        }
        let children = configs.compactMap { config -> SuwayomiServerSourceConfig? in
            if case let .suwayomiServerSource(values) = config { return values }
            return nil
        }
        for parentKey in parents {
            await syncOne(parentKey: parentKey, existing: children.filter { $0.parentKey == parentKey })
        }
    }

    static func syncOne(parentKey: String, existing: [SuwayomiServerSourceConfig]) async {
        let helper = SuwayomiHelper(sourceKey: parentKey)
        var saved: [String] = []
        let result = await sync(
            parentKey: parentKey,
            existing: existing,
            fetch: {
                let response: SuwayomiSourcesResponse = try await helper.request(
                    body: SuwayomiServerSourcesPayload(),
                    timeout: SuwayomiServerSources.sourcesTimeout
                )
                return response.data.sources.nodes
            },
            prepare: { changes in
                // icons with the connection's login, before the sources are built with them
                await withTaskGroup(of: Void.self) { group in
                    for config in changes where config.available {
                        group.addTask { await SuwayomiServerSourceIcons.download(config, helper: helper) }
                    }
                }
            },
            save: { config in
                await SourceManager.shared.addOrUpdateCustomSource(config: .suwayomiServerSource(config))
            }
        )
        for config in existing + SuwayomiConnections.shared.children(of: parentKey) {
            saved.append(config.key)
        }
        if result.answered {
            // the marks per device («Fuentes del servidor») and the cached list are gone
            UserDefaults.standard.removeObject(forKey: "\(parentKey).serverSources")
            UserDefaults.standard.removeObject(forKey: "\(parentKey).serverSourcesSnapshot")
        }
        if result.added + result.updated + result.unavailable > 0 {
            await SourceManager.shared.publishSourceChanges(keys: Array(Set(saved)))
        }
        LogManager.logger.info(
            "Suwayomi sources of \(parentKey): answered \(result.answered), added \(result.added), "
                + "updated \(result.updated), unavailable \(result.unavailable)"
        )
    }
}
