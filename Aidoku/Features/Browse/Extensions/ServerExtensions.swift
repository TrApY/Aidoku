//
//  ServerExtensions.swift
//  Aidoku
//
//  SUWA-12 B3: the extensions of the Suwayomi SERVER (GraphQL), as Tachimanga's Extensiones: pending
//  updates, installed, and available by language. Installing or removing one resyncs the server sources
//  (D4) so it appears or goes in Fuentes without restarting.
//

import Foundation

struct ServerExtension: Decodable, Equatable, Identifiable, Sendable {
    enum ContentWarning: String, Decodable, Sendable {
        case safe = "SAFE"
        case mixed = "MIXED"
        case nsfw = "NSFW"
        case unknown

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = ContentWarning(rawValue: value) ?? .unknown
        }
    }

    struct SourceIds: Decodable, Equatable, Sendable {
        struct Node: Decodable, Equatable, Sendable {
            let id: String
        }
        let nodes: [Node]
    }

    let pkgName: String
    let name: String
    let lang: String
    let versionName: String
    var isInstalled: Bool
    var hasUpdate: Bool
    let isObsolete: Bool
    let iconUrl: String
    let contentWarning: ContentWarning
    let source: SourceIds

    var id: String { pkgName }
    var serverSourceIds: [String] { source.nodes.map(\.id) }
    /// «18+»: the extension is for adults.
    var isNsfw: Bool { contentWarning == .nsfw }
    /// Some of its content is for adults.
    var isPartlyNsfw: Bool { contentWarning == .mixed }
    /// «Mixto»: several languages.
    var isMultiLanguage: Bool { BrowseLanguages.code(lang) == SourceLanguage.multi }
}

struct ServerExtensionSections: Equatable {
    struct LanguageGroup: Equatable {
        let code: String
        let extensions: [ServerExtension]
    }

    var updates: [ServerExtension] = []
    var installed: [ServerExtension] = []
    var available: [LanguageGroup] = []

    var isEmpty: Bool { updates.isEmpty && installed.isEmpty && available.isEmpty }

    /// Pending updates and installed ones always show (so they can be updated or removed); the available
    /// ones only in the active languages. A search narrows the three by name (without case or accents).
    static func make(
        _ extensions: [ServerExtension],
        active: Set<String>,
        query: String = "",
        localCode: String? = Locale.current.languageCode
    ) -> ServerExtensionSections {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? extensions : extensions.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        func byName(_ lhs: ServerExtension, _ rhs: ServerExtension) -> Bool {
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        var result = ServerExtensionSections()
        result.updates = matching.filter { $0.isInstalled && $0.hasUpdate }.sorted(by: byName)
        result.installed = matching.filter { $0.isInstalled && !$0.hasUpdate }.sorted(by: byName)
        let available = matching.filter {
            !$0.isInstalled && !$0.isObsolete && BrowseLanguages.isVisible([$0.lang], active: active)
        }
        let grouped = Dictionary(grouping: available) { BrowseLanguages.code($0.lang) }
        let local = localCode.map(BrowseLanguages.code)
        let codes = grouped.keys.sorted { lhs, rhs in
            if lhs == local { return true }
            if rhs == local { return false }
            if lhs == SourceLanguage.multi { return false }
            if rhs == SourceLanguage.multi { return true }
            return SourceLanguage.compare(lhs, rhs) == .orderedAscending
        }
        result.available = codes.map { .init(code: $0, extensions: (grouped[$0] ?? []).sorted(by: byName)) }
        return result
    }
}

/// What the Extensiones tab asks the server.
protocol ServerExtensionsAPI: Sendable {
    func list() async throws -> [ServerExtension]
    /// Refreshes the server's extension repository (pull to refresh).
    func fetch() async throws -> [ServerExtension]
    func apply(_ action: ServerExtensionAction, to pkgName: String) async throws
    func apply(_ action: ServerExtensionAction, to pkgNames: [String]) async throws
}

enum ServerExtensionAction: String, Sendable {
    case install
    case update
    case uninstall
}

/// At most `limit` jobs at once.
actor ServerExtensionLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        if running >= limit {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiters.isEmpty {
                running -= 1
            } else {
                waiters.removeFirst().resume() // the slot goes to the next one
            }
        }
        return try await work()
    }
}

@MainActor
final class ServerExtensionsModel: ObservableObject {
    enum State: Equatable {
        case noConnection
        case loading
        case failed
        case loaded
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var extensions: [ServerExtension] = []
    /// What each extension is doing right now.
    @Published private(set) var busy: [String: ServerExtensionAction] = [:]
    @Published private(set) var lastError: String?

    private let api: (any ServerExtensionsAPI)?
    private let resync: @Sendable () async -> Void
    private let libraryCount: @Sendable ([String]) async -> Int
    private let limiter = ServerExtensionLimiter(limit: 2)

    /// - api: nil without a Suwayomi connection.
    /// - resync: the server sources again (D4), after installing, updating or removing.
    /// - libraryCount: library manga of the given server source ids.
    init(
        api: (any ServerExtensionsAPI)?,
        resync: @escaping @Sendable () async -> Void,
        libraryCount: @escaping @Sendable ([String]) async -> Int
    ) {
        self.api = api
        self.resync = resync
        self.libraryCount = libraryCount
        self.state = api == nil ? .noConnection : .loading
    }

    func load(refresh: Bool = false) async {
        guard let api else {
            state = .noConnection
            return
        }
        if extensions.isEmpty {
            state = .loading
        }
        do {
            extensions = refresh ? try await api.fetch() : try await api.list()
            ServerExtensionLanguages.known = Array(Set(extensions.map(\.lang)))
            state = .loaded
        } catch {
            LogManager.logger.warn("Suwayomi extensions not loaded: \(error)")
            if extensions.isEmpty {
                state = .failed
            }
            lastError = error.localizedDescription
        }
    }

    /// Library manga coming from this extension (removing it asks twice if there are any).
    func libraryMangaCount(of ext: ServerExtension) async -> Int {
        await libraryCount(ext.serverSourceIds)
    }

    func perform(_ action: ServerExtensionAction, on ext: ServerExtension) async {
        guard let api, busy[ext.pkgName] == nil else { return }
        busy[ext.pkgName] = action
        defer { busy[ext.pkgName] = nil }
        do {
            try await limiter.run {
                try await api.apply(action, to: ext.pkgName)
            }
            lastError = nil
        } catch {
            LogManager.logger.warn("Suwayomi extension \(ext.pkgName) \(action.rawValue) failed: \(error)")
            lastError = error.localizedDescription
        }
        await resync()
        await load()
    }

    func updateAll() async {
        guard let api else { return }
        let pending = extensions.filter { $0.isInstalled && $0.hasUpdate }.map(\.pkgName)
        guard !pending.isEmpty else { return }
        for pkgName in pending {
            busy[pkgName] = .update
        }
        do {
            try await api.apply(.update, to: pending)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        for pkgName in pending {
            busy[pkgName] = nil
        }
        await resync()
        await load()
    }
}
