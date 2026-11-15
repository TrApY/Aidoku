//
//  SuwayomiServerSourceConfig.swift
//  Aidoku
//
//  A source installed on a Suwayomi server, shown as an Aidoku source of its own (as Tachimanga does).
//  The «parent» (the Suwayomi source created in the setup) is only the connection: server, login and
//  tokens live under its key, and every child reads them from there.
//

import AidokuRunner
import Foundation

/// What a child source needs to be built without asking the server (offline start).
struct SuwayomiServerSourceConfig: Equatable, Sendable {
    /// `<parentKey>.<serverSourceId>`: keeps the «suwayomi» prefix and is a valid folder name.
    let key: String
    /// The connection (the Suwayomi source of the setup).
    let parentKey: String
    /// The source id on the server (64 bits, as text).
    let serverSourceId: String
    /// The server's `name` («Olympus Scanlation»), without the « (ES)» of `displayName`: Aidoku shows the
    /// language apart.
    var name: String
    /// The server's `lang` (`es`, `es-419`, `all`…).
    var lang: String
    /// The server's icon path (`/api/v1/extension/icon/…`), relative to the server.
    var iconUrl: String
    /// Suwayomi's «may contain NSFW».
    var isNsfw: Bool
    var supportsLatest: Bool
    /// False while the source is not installed on the server anymore: hidden from the lists, its manga
    /// keep working (it is never removed, that would remove its settings and tracking).
    var available: Bool

    static func key(parentKey: String, serverSourceId: String) -> String {
        "\(parentKey).\(serverSourceId)"
    }

    /// The child of `parentKey` for a source of the server list.
    init(parentKey: String, server source: SuwayomiServerSource) {
        self.key = Self.key(parentKey: parentKey, serverSourceId: source.id)
        self.parentKey = parentKey
        self.serverSourceId = source.id
        self.name = source.name.isEmpty ? source.displayName : source.name
        self.lang = source.lang
        self.iconUrl = source.iconUrl ?? ""
        self.isNsfw = source.isNsfw
        self.supportsLatest = source.supportsLatest
        self.available = true
    }

    init(
        key: String,
        parentKey: String,
        serverSourceId: String,
        name: String,
        lang: String,
        iconUrl: String,
        isNsfw: Bool,
        supportsLatest: Bool,
        available: Bool
    ) {
        self.key = key
        self.parentKey = parentKey
        self.serverSourceId = serverSourceId
        self.name = name
        self.lang = lang
        self.iconUrl = iconUrl
        self.isNsfw = isNsfw
        self.supportsLatest = supportsLatest
        self.available = available
    }

    /// Aidoku language of the source (`all` of the server = Aidoku's `multi`).
    var languages: [String] {
        lang.lowercased() == "all" ? [SourceLanguage.multi] : [lang]
    }

    /// Suwayomi's `isNsfw` means «may contain», as Aidoku's `.containsNsfw`.
    var contentRating: AidokuRunner.SourceContentRating {
        isNsfw ? .containsNsfw : .safe
    }

    /// Strings and flags after the type byte (the decoder never requires the end: fields can be added later).
    var codingStrings: [String] { [key, parentKey, serverSourceId, name, lang, iconUrl] }
    var codingFlags: UInt8 {
        (isNsfw ? 1 : 0) | (supportsLatest ? 2 : 0) | (available ? 0 : 4)
    }

    init(strings: [String], flags: UInt8) throws {
        guard strings.count == 6 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid server source"))
        }
        self.init(
            key: strings[0],
            parentKey: strings[1],
            serverSourceId: strings[2],
            name: strings[3],
            lang: strings[4],
            iconUrl: strings[5],
            isNsfw: flags & 1 != 0,
            supportsLatest: flags & 2 != 0,
            available: flags & 4 == 0
        )
    }
}

/// Which Suwayomi connection each Suwayomi source key uses, from the saved configs (never by parsing the
/// key): the ONE place that answers «where are the server and the login of this source». Filled when the
/// configs are turned into sources (start, sync, backups).
final class SuwayomiConnections: @unchecked Sendable {
    static let shared = SuwayomiConnections()

    private let lock = NSLock()
    private var connections = Set<String>()
    private var children: [String: SuwayomiServerSourceConfig] = [:]

    func register(connection key: String) {
        lock.withLock { _ = connections.insert(key) }
    }

    func register(child config: SuwayomiServerSourceConfig) {
        lock.withLock { children[config.key] = config }
    }

    func unregister(_ key: String) {
        lock.withLock {
            connections.remove(key)
            children[key] = nil
        }
    }

    /// The key whose `.server`, `.login*`, `.cookie`, `.token` are used: the parent for a child, the key
    /// itself otherwise (the parent, an old track id `<parent>|<id>`, another self-hosted source).
    func connectionKey(for sourceKey: String) -> String {
        lock.withLock { children[sourceKey]?.parentKey ?? sourceKey }
    }

    func child(_ key: String) -> SuwayomiServerSourceConfig? {
        lock.withLock { children[key] }
    }

    func isConnection(_ key: String) -> Bool {
        lock.withLock { connections.contains(key) }
    }

    func children(of parentKey: String) -> [SuwayomiServerSourceConfig] {
        lock.withLock { children.values.filter { $0.parentKey == parentKey } }
    }

    /// False for what must not be offered as a source (Explorar, search, migration targets): a connection,
    /// and a child the server doesn't have anymore.
    func isListed(_ key: String) -> Bool {
        lock.withLock {
            if connections.contains(key) { return false }
            if let child = children[key] { return child.available }
            return true
        }
    }

    /// Tests.
    func removeAll() {
        lock.withLock {
            connections.removeAll()
            children.removeAll()
        }
    }
}

extension SuwayomiServerSources {
    /// «Populares» and, if the server source supports it, «Recientes».
    static func childListings(for config: SuwayomiServerSourceConfig) -> [AidokuRunner.Listing] {
        var listings: [AidokuRunner.Listing] = [
            .init(id: "popular-\(config.serverSourceId)", name: NSLocalizedString("SUWAYOMI_POPULAR"), kind: .default)
        ]
        if config.supportsLatest {
            listings.append(.init(id: "latest-\(config.serverSourceId)", name: NSLocalizedString("SUWAYOMI_LATEST"), kind: .default))
        }
        return listings
    }
}

/// Limits the searches running at once against one Suwayomi server (every server source of a connection
/// goes to the same server; global search and migration search several sources at a time).
actor SuwayomiSearchLimiter {
    static let maxConcurrentSearches = 4

    private static let lock = NSLock()
    nonisolated(unsafe) private static var limiters: [String: SuwayomiSearchLimiter] = [:]

    /// The limiter of a connection.
    static func shared(for connectionKey: String) -> SuwayomiSearchLimiter {
        lock.withLock {
            if let limiter = limiters[connectionKey] { return limiter }
            let limiter = SuwayomiSearchLimiter()
            limiters[connectionKey] = limiter
            return limiter
        }
    }

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = SuwayomiSearchLimiter.maxConcurrentSearches) {
        self.limit = limit
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // the slot is handed over by `release` (running stays the same)
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// The icons of the server sources, downloaded with the connection's login and kept on disk (the
/// source lists load icons without authentication).
enum SuwayomiServerSourceIcons {
    static var directory: URL {
        FileManager.default.applicationSupportDirectory.appendingPathComponent("SuwayomiIcons", isDirectory: true)
    }

    static func fileUrl(sourceKey: String) -> URL {
        directory.appendingPathComponent("\(sourceKey.directoryName).png")
    }

    static func storedIconUrl(sourceKey: String) -> URL? {
        let url = fileUrl(sourceKey: sourceKey)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads the icon if it isn't stored yet (best effort).
    static func download(_ config: SuwayomiServerSourceConfig, helper: SuwayomiHelper) async {
        let destination = fileUrl(sourceKey: config.key)
        guard
            !FileManager.default.fileExists(atPath: destination.path),
            !config.iconUrl.isEmpty,
            let baseUrl = try? helper.getConfiguredServer(),
            let url = SuwayomiServerSources.iconUrl(config.iconUrl, baseUrl: baseUrl)
        else { return }
        var request = URLRequest(url: url, timeoutInterval: SuwayomiServerSources.sourcesTimeout)
        helper.authorize(request: &request)
        do {
            let (data, response) = try await helper.transport(request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
            directory.createDirectory()
            try data.write(to: destination, options: .atomic)
        } catch {
            LogManager.logger.warn("Icon of \(config.key) not downloaded: \(error)")
        }
    }
}
