//
//  SuwayomiRecs.swift
//  Aidoku
//
//  SUWA-18: «Para ti» (Explorar) and «Relacionados» (manga page), read from the metas the suwa-recs
//  service writes on the Suwayomi server. The app only READS them (never writes to the server) and only
//  reads again on pull to refresh: nothing is computed here. Nothing goes to Core Data or UserDefaults: a
//  memory cache per session and a copy in Caches/.
//

import AidokuRunner
import Foundation

enum SuwayomiRecs {
    /// Global meta: «Para ti» (up to 20).
    static let forYouKey = "suwa.recs.v1"
    /// Manga meta (library manga only): «Relacionados» (up to 10).
    static let relatedKey = "suwa.related.v1"
    /// Global meta: state of the last run.
    static let statusKey = "suwa.recs.estado.v1"
    /// Longest wait for a whole read (meta + titles and covers).
    static let timeout: TimeInterval = 10

    /// One recommendation of the meta: `m` manga id, `s` server source id, `p` score, `r` reason.
    struct Item: Equatable, Sendable {
        let mangaId: Int
        let serverSourceId: String
        let score: Double?
        let reason: String
    }

    /// A decoded meta value (D3). Anything not valid is `empty`.
    struct List: Equatable, Sendable {
        let at: String?
        let items: [Item]

        static let empty = List(at: nil, items: [])
    }

    /// `suwa.recs.estado.v1`.
    struct Status: Equatable, Sendable, Codable {
        let at: String?
        let ok: Bool
        let message: String?
    }

    /// What is shown for a recommendation (titles and covers come from the server, not from the meta).
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        let mangaId: Int
        /// The child source `<connection>.<server source id>`.
        let sourceKey: String
        let title: String
        let cover: String?
        let reason: String
        let sourceName: String

        var id: Int { mangaId }

        var manga: AidokuRunner.Manga {
            .init(sourceKey: sourceKey, key: "\(mangaId)", title: title, cover: cover)
        }
    }

    /// «Para ti»: the list, its date (`at` of `suwa.recs.v1`) and the state of the last run.
    struct ForYouResult: Codable, Equatable, Sendable {
        let at: String?
        let entries: [Entry]
        let status: Status?
    }

    // MARK: Decoding (D3)

    private struct RawList: Decodable {
        let v: Int?
        let at: String?
        let items: [RawItem]?

        enum CodingKeys: String, CodingKey { case v, at, items }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try? container.decodeIfPresent(Int.self, forKey: .v)
            at = try? container.decodeIfPresent(String.self, forKey: .at)
            items = try? container.decodeIfPresent([RawItem].self, forKey: .items)
        }
    }

    /// Every field is optional and of the right type or nil: one bad element never drops the others.
    private struct RawItem: Decodable {
        let m: Int?
        let s: String?
        let p: Double?
        let r: String?

        enum CodingKeys: String, CodingKey { case m, s, p, r }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            m = try? container?.decodeIfPresent(Int.self, forKey: .m)
            s = (try? container?.decodeIfPresent(String.self, forKey: .s))
                ?? (try? container?.decodeIfPresent(Int64.self, forKey: .s)).map { String($0) }
            p = try? container?.decodeIfPresent(Double.self, forKey: .p)
            r = try? container?.decodeIfPresent(String.self, forKey: .r)
        }
    }

    private struct RawStatus: Decodable {
        let v: Int?
        let at: String?
        let ok: Bool?
        let msg: String?
    }

    /// A meta value: `v` other than 1, broken JSON or no `items` = empty; extra fields are ignored and
    /// incomplete elements (no manga id or no source id) skipped; a repeated manga keeps its first place.
    static func decode(_ value: String?) -> List {
        return .empty // pendiente[A1#1]
    }

    /// `suwa.recs.estado.v1` (nil if missing or not valid).
    static func decodeStatus(_ value: String?) -> Status? {
        return nil // pendiente[A1#2]
    }

    /// The child source of a server source id, as the app keys it (`SuwayomiServerSourceConfig.key`).
    static func childKey(parentKey: String, serverSourceId: String) -> String {
        "" // pendiente[A1#3]
    }

    /// The entries in the meta's order: ids the server doesn't have anymore are skipped, and so are manga
    /// already in the library (and `excluding`, the manga whose page is shown).
    static func entries(
        items: [Item],
        nodes: [MangaNode],
        parentKey: String,
        baseUrl: URL,
        excluding: Int? = nil,
        sourceName: (String) -> String? = { SuwayomiConnections.shared.child($0)?.name }
    ) -> [Entry] {
        return [] // pendiente[A1#4]
    }

    // MARK: Manga page (A2)

    /// The manga whose «Relacionados» can be read: a library manga of a server source (nil otherwise, and
    /// then nothing is asked to the server and nothing is drawn).
    static func relatedTarget(
        sourceKey: String,
        mangaKey: String,
        inLibrary: Bool,
        child: (String) -> SuwayomiServerSourceConfig? = { SuwayomiConnections.shared.child($0) }
    ) -> (parentKey: String, mangaId: Int)? {
        return nil // pendiente[A2#5]
    }

    /// The section is drawn only with entries (no gap and no loading text otherwise).
    static func showsRelated(_ entries: [Entry]) -> Bool {
        false // pendiente[A2#6]
    }

    /// «Relacionados» of a manga page: memory cache of the session unless `force` (pull to refresh); a
    /// failed read falls back to the copy in Caches/, and to nothing.
    static func loadRelated(
        sourceKey: String,
        mangaKey: String,
        inLibrary: Bool,
        force: Bool = false,
        cache: SuwayomiRecsCache = .shared,
        transport: SuwayomiHelper.Transport? = nil,
        child: (String) -> SuwayomiServerSourceConfig? = { SuwayomiConnections.shared.child($0) }
    ) async -> [Entry] {
        guard let target = relatedTarget(sourceKey: sourceKey, mangaKey: mangaKey, inLibrary: inLibrary, child: child) else {
            return []
        }
        return [] // pendiente[A2#7]
    }

    // MARK: Explorar › Para ti (A3)

    /// «Actualizado: <fecha>» from the `at` of `suwa.recs.v1` (nil if it can't be read).
    static func updatedText(
        at: String?,
        format: String = NSLocalizedString("FOR_YOU_UPDATED"),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        return nil // pendiente[A3#8]
    }

    // MARK: Server answers

    struct MangaNode: Decodable, Sendable {
        let id: Int
        let title: String?
        let thumbnailUrl: String?
        let inLibrary: Bool?
        let sourceId: String?
        let source: Source?

        struct Source: Decodable, Sendable {
            let displayName: String?
        }
    }

    struct MetaNode: Decodable, Sendable {
        let key: String?
        let value: String?
    }

    struct MetaConnection: Decodable, Sendable {
        let nodes: [MetaNode]?
    }

    /// Every field optional: an answer with GraphQL `errors` (a key or manga that doesn't exist) decodes
    /// as «no data» instead of failing.
    struct ForYouResponse: Decodable, Sendable {
        let data: DataContainer?

        struct DataContainer: Decodable, Sendable {
            let recs: MetaConnection?
            let estado: MetaConnection?
        }
    }

    struct RelatedResponse: Decodable, Sendable {
        let data: DataContainer?

        struct DataContainer: Decodable, Sendable {
            let manga: Manga?
        }

        struct Manga: Decodable, Sendable {
            let meta: [MetaNode]?
        }
    }

    struct MangasResponse: Decodable, Sendable {
        let data: DataContainer?

        struct DataContainer: Decodable, Sendable {
            let mangas: Connection?
        }

        struct Connection: Decodable, Sendable {
            let nodes: [MangaNode]?
        }
    }

    /// Runs `operation` for at most `seconds` (URLRequest timeouts are idle timeouts, not deadlines).
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw SourceError.networkError
            }
            return value
        }
    }
}

/// Reads the metas of one Suwayomi connection (read only: queries, never mutations).
struct SuwayomiRecsReader: Sendable {
    let parentKey: String
    let helper: SuwayomiHelper
    let deadline: TimeInterval

    init(parentKey: String, transport: SuwayomiHelper.Transport? = nil, deadline: TimeInterval = SuwayomiRecs.timeout) {
        self.parentKey = parentKey
        self.helper = SuwayomiHelper(sourceKey: parentKey, transport: transport)
        self.deadline = deadline
    }

    private struct ForYouPayload: Encodable {
        let operationName = "SuwaRecsForYou"
        // metas(condition:) gives an empty list for a key that doesn't exist (meta(key:) gives an error)
        let query = """
            query SuwaRecsForYou {
              recs: metas(condition: {key: "\(SuwayomiRecs.forYouKey)"}) {
                nodes { key value }
              }
              estado: metas(condition: {key: "\(SuwayomiRecs.statusKey)"}) {
                nodes { key value }
              }
            }
            """
    }

    private struct RelatedPayload: Encodable {
        let operationName = "SuwaRecsRelated"
        let variables: Variables
        let query = """
            query SuwaRecsRelated($mangaId: Int!) {
              manga(id: $mangaId) {
                meta { key value }
              }
            }
            """

        struct Variables: Encodable {
            let mangaId: Int
        }
    }

    private struct MangasPayload: Encodable {
        let operationName = "SuwaRecsMangas"
        let variables: Variables
        let query = """
            query SuwaRecsMangas($ids: [Int!]!) {
              mangas(filter: {id: {in: $ids}}) {
                nodes { id title thumbnailUrl inLibrary sourceId source { displayName } }
              }
            }
            """

        struct Variables: Encodable {
            let ids: [Int]
        }
    }

    func forYou() async throws -> SuwayomiRecs.ForYouResult {
        return .init(at: nil, entries: [], status: nil) // pendiente[A1#9]
    }

    func related(mangaId: Int) async throws -> [SuwayomiRecs.Entry] {
        return [] // pendiente[A2#10]
    }

    /// Titles and covers of the items, in one query (none when there are no items).
    private func resolve(_ items: [SuwayomiRecs.Item], baseUrl: URL, excluding: Int?) async throws -> [SuwayomiRecs.Entry] {
        let ids = items.map(\.mangaId).filter { $0 != excluding }
        guard !ids.isEmpty else { return [] }
        let response: SuwayomiRecs.MangasResponse = try await helper.request(
            body: MangasPayload(variables: .init(ids: ids)),
            timeout: deadline
        )
        return SuwayomiRecs.entries(
            items: items,
            nodes: response.data?.mangas?.nodes ?? [],
            parentKey: parentKey,
            baseUrl: baseUrl,
            excluding: excluding
        )
    }
}

/// Memory cache per session plus a copy in Caches/ (shown when the server can't be read).
actor SuwayomiRecsCache {
    static let shared = SuwayomiRecsCache(
        directory: FileManager.default.cachesDirectory.appendingPathComponent("SuwayomiRecs", isDirectory: true)
    )

    private let directory: URL?
    private var values: [String: Data] = [:]

    /// `directory` nil: memory only (tests).
    init(directory: URL?) {
        self.directory = directory
    }

    private func fileUrl(_ key: String) -> URL? {
        directory?.appendingPathComponent("\(key.directoryName.replacingOccurrences(of: "|", with: "_")).json")
    }

    /// Read in this session.
    func memory<T: Decodable & Sendable>(_ key: String) -> T? {
        values[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    /// Read in an earlier session (Caches/).
    func stored<T: Decodable & Sendable>(_ key: String) -> T? {
        if let value: T = memory(key) { return value }
        guard let url = fileUrl(key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func set<T: Encodable & Sendable>(_ value: T, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        values[key] = data
        if let directory, let url = fileUrl(key) {
            directory.createDirectory()
            try? data.write(to: url, options: .atomic)
        }
    }

    func removeAll() {
        values.removeAll()
    }
}
