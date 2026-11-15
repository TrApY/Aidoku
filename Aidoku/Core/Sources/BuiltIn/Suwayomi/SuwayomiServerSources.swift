//
//  SuwayomiServerSources.swift
//  Aidoku
//
//  Browsing and searching the sources installed on a Suwayomi server.
//  Pure helpers (request building, response parsing, listing ids) kept apart
//  from the runner so they can be unit tested.
//

import AidokuRunner
import Foundation

// MARK: Models

/// A source (extension language) installed on the Suwayomi server.
struct SuwayomiServerSource: Codable, Sendable, Hashable {
    let id: String
    let name: String
    let lang: String
    let displayName: String
    let isNsfw: Bool
    let supportsLatest: Bool
    let iconUrl: String?
}

struct SuwayomiSourcesResponse: Decodable, Sendable {
    let data: DataContainer

    struct DataContainer: Decodable, Sendable {
        let sources: SourceConnection
    }

    struct SourceConnection: Decodable, Sendable {
        let nodes: [SuwayomiServerSource]
    }
}

enum SuwayomiFetchSourceMangaType: String, Encodable, Sendable {
    case search = "SEARCH"
    case popular = "POPULAR"
    case latest = "LATEST"
}

struct SuwayomiFetchSourceMangaResponse: Decodable, Sendable {
    let data: DataContainer

    struct DataContainer: Decodable, Sendable {
        let fetchSourceManga: Result
    }

    struct Result: Decodable, Sendable {
        let mangas: [SuwayomiMangaNode]
        let hasNextPage: Bool
    }
}

/// Responses of the mutations whose result only has to exist (decoding fails when the server returns null).
struct SuwayomiFetchMangaResponse: Decodable, Sendable {
    let data: DataContainer

    struct DataContainer: Decodable, Sendable {
        let fetchManga: Payload
    }

    struct Payload: Decodable, Sendable {
        let manga: Manga
    }

    struct Manga: Decodable, Sendable {
        let id: Int
    }
}

struct SuwayomiFetchChaptersResponse: Decodable, Sendable {
    let data: DataContainer

    struct DataContainer: Decodable, Sendable {
        let fetchChapters: Payload
    }

    struct Payload: Decodable, Sendable {
        let chapters: [Chapter]
    }

    struct Chapter: Decodable, Sendable {
        let id: Int
    }
}

struct SuwayomiUpdateMangaResponse: Decodable, Sendable {
    let data: DataContainer

    struct DataContainer: Decodable, Sendable {
        let updateManga: Payload
    }

    struct Payload: Decodable, Sendable {
        let manga: Manga
    }

    struct Manga: Decodable, Sendable {
        let id: Int
        let inLibrary: Bool
    }
}

struct SuwayomiInLibraryResponse: Decodable, Sendable {
    let data: DataContainer

    struct DataContainer: Decodable, Sendable {
        let manga: Manga
    }

    struct Manga: Decodable, Sendable {
        let inLibrary: Bool
    }
}

// MARK: Payloads

struct SuwayomiServerSourcesPayload: Encodable, Sendable {
    let query = """
        query GetServerSources {
          sources {
            nodes {
              id
              name
              lang
              displayName
              isNsfw
              supportsLatest
              iconUrl
            }
          }
        }
        """
}

struct SuwayomiFetchSourceMangaPayload: Encodable, Sendable, Equatable {
    let variables: Variables
    let query = """
        mutation FetchSourceManga($source: LongString!, $type: FetchSourceMangaType!, $page: Int!, $query: String) {
          fetchSourceManga(input: {source: $source, type: $type, page: $page, query: $query}) {
            mangas {
              id
              title
              thumbnailUrl
              author
              artist
              inLibrary
            }
            hasNextPage
          }
        }
        """

    struct Variables: Encodable, Sendable, Equatable {
        let source: String
        let type: SuwayomiFetchSourceMangaType
        let page: Int
        let query: String?
    }
}

struct SuwayomiFetchMangaPayload: Encodable, Sendable {
    let variables: Variables
    let query = """
        mutation FetchManga($id: Int!) {
          fetchManga(input: {id: $id}) {
            manga {
              id
            }
          }
        }
        """

    struct Variables: Encodable, Sendable {
        let id: Int
    }
}

struct SuwayomiFetchChaptersPayload: Encodable, Sendable {
    let variables: Variables
    let query = """
        mutation FetchChapters($mangaId: Int!) {
          fetchChapters(input: {mangaId: $mangaId}) {
            chapters {
              id
            }
          }
        }
        """

    struct Variables: Encodable, Sendable {
        let mangaId: Int
    }
}

struct SuwayomiInLibraryPayload: Encodable, Sendable {
    let variables: Variables
    let query = """
        query GetInLibrary($id: Int!) {
          manga(id: $id) {
            inLibrary
          }
        }
        """

    struct Variables: Encodable, Sendable {
        let id: Int
    }
}

struct SuwayomiAddToLibraryPayload: Encodable, Sendable {
    let variables: Variables
    let query = """
        mutation AddToServerLibrary($id: Int!) {
          updateManga(input: {id: $id, patch: {inLibrary: true}}) {
            manga {
              id
              inLibrary
            }
          }
        }
        """

    struct Variables: Encodable, Sendable {
        let id: Int
    }
}

// MARK: Logic

/// Where a search goes, from the "search in" filter.
enum SuwayomiSearchTarget: Equatable, Sendable {
    /// The server library and every source chosen in the settings (default).
    case all
    /// Only the server library, with its filters.
    case library
    /// One server source.
    case source(String)
}

enum SuwayomiServerSources {
    /// Id of the server's built-in local source, never offered.
    static let localSourceId = "0"
    /// Settings key (namespaced by the source key) holding the selected server source ids.
    static let settingKey = "serverSources"
    /// Search filter id for choosing where to search.
    static let searchInFilterId = "searchIn"
    /// Fetching from the origin websites can be slow.
    static let fetchTimeout: TimeInterval = 90
    /// Searching one server source.
    static let searchSourceTimeout: TimeInterval = 30
    /// Listing the installed sources must not block settings or listings when the server is down.
    static let sourcesTimeout: TimeInterval = 10

    static func defaultsKey(sourceKey: String) -> String {
        "\(sourceKey).\(settingKey)"
    }

    /// Last list of installed sources received from the server (all of them, unfiltered).
    static func snapshotKey(sourceKey: String) -> String {
        "\(sourceKey).serverSourcesSnapshot"
    }

    /// Sources to search in «Todo»: the selected ones, in the settings order and without NSFW if hidden.
    static func searchSources(
        selectedIds: [String],
        known: [SuwayomiServerSource],
        allowNsfw: Bool
    ) -> [SuwayomiServerSource] {
        selected(ids: selectedIds, from: available(known, allowNsfw: allowNsfw))
    }

    /// Suwayomi's `isNsfw` is the extension flag "may contain NSFW content",
    /// the equivalent of Aidoku's `containsNsfw` rating.
    static func allowsNsfw(contentRatings: Set<AidokuRunner.SourceContentRating>) -> Bool {
        contentRatings.contains(.containsNsfw) || contentRatings.contains(.primarilyNsfw)
    }

    /// Sources that can be offered in the setting: everything but the local source,
    /// and without NSFW sources when the app hides NSFW content.
    static func available(_ sources: [SuwayomiServerSource], allowNsfw: Bool) -> [SuwayomiServerSource] {
        sources.filter { $0.id != localSourceId && (allowNsfw || !$0.isNsfw) }
    }

    /// Selected sources, in the order they appear in the setting.
    static func selected(ids: [String], from available: [SuwayomiServerSource]) -> [SuwayomiServerSource] {
        let ids = Set(ids)
        return available.filter { ids.contains($0.id) }
    }

    static func listings(for sources: [SuwayomiServerSource]) -> [AidokuRunner.Listing] {
        sources.flatMap { source in
            var listings: [AidokuRunner.Listing] = [
                .init(
                    id: "popular-\(source.id)",
                    name: String(format: NSLocalizedString("SUWAYOMI_LISTING_POPULAR"), source.displayName),
                    kind: .default
                )
            ]
            if source.supportsLatest {
                listings.append(.init(
                    id: "latest-\(source.id)",
                    name: String(format: NSLocalizedString("SUWAYOMI_LISTING_LATEST"), source.displayName),
                    kind: .default
                ))
            }
            return listings
        }
    }

    /// Parses a listing id created by `listings(for:)`.
    static func parseListingId(_ id: String) -> (type: SuwayomiFetchSourceMangaType, sourceId: String)? {
        for (prefix, type) in [("popular-", SuwayomiFetchSourceMangaType.popular), ("latest-", .latest)]
            where id.hasPrefix(prefix)
        {
            let sourceId = String(id.dropFirst(prefix.count))
            return sourceId.isEmpty ? nil : (type, sourceId)
        }
        return nil
    }

    static func listingPayload(listingId: String, page: Int) -> SuwayomiFetchSourceMangaPayload? {
        guard let (type, sourceId) = parseListingId(listingId) else { return nil }
        return .init(variables: .init(source: sourceId, type: type, page: page, query: nil))
    }

    /// Search inside a server source; without text it shows the popular list.
    static func searchPayload(sourceId: String, query: String?, page: Int) -> SuwayomiFetchSourceMangaPayload {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query, !query.isEmpty {
            return .init(variables: .init(source: sourceId, type: .search, page: page, query: query))
        }
        return .init(variables: .init(source: sourceId, type: .popular, page: page, query: nil))
    }

    /// The raw value of the "search in" filter: a server source id, `searchInLibraryId`,
    /// or nil when absent or empty («Todo»).
    static func searchSourceId(filters: [AidokuRunner.FilterValue]) -> String? {
        for filter in filters {
            if case let .select(id, value) = filter, id == searchInFilterId, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func searchInFilter(sources: [SuwayomiServerSource]) -> AidokuRunner.Filter? {
        guard !sources.isEmpty else { return nil }
        return .init(
            id: searchInFilterId,
            title: NSLocalizedString("SUWAYOMI_SEARCH_IN"),
            value: .select(.init(
                options: [NSLocalizedString("SUWAYOMI_SEARCH_ALL"), NSLocalizedString("LIBRARY")] + sources.map(\.displayName),
                ids: ["", searchInLibraryId] + sources.map(\.id),
                defaultValue: ""
            ))
        )
    }

    static func setting(sources: [SuwayomiServerSource]) -> AidokuRunner.Setting? {
        guard !sources.isEmpty else { return nil }
        return .init(
            title: "SUWAYOMI_SERVER_SOURCES",
            value: .group(.init(
                footer: "SUWAYOMI_SERVER_SOURCES_INFO",
                items: [
                    .init(
                        key: settingKey,
                        title: "SUWAYOMI_SERVER_SOURCES",
                        refreshes: ["listings", "filters"],
                        value: .multiselect(.init(
                            values: sources.map(\.id),
                            titles: sources.map(\.displayName)
                        ))
                    )
                ]
            ))
        )
    }

    static func mangaPage(
        _ response: SuwayomiFetchSourceMangaResponse,
        sourceKey: String,
        baseUrl: URL
    ) -> AidokuRunner.MangaPageResult {
        .init(
            entries: response.data.fetchSourceManga.mangas.compactMap { $0.intoManga(sourceKey: sourceKey, baseUrl: baseUrl) },
            hasNextPage: response.data.fetchSourceManga.hasNextPage
        )
    }

    static let libraryListingId = "library"

    // MARK: Search everywhere

    /// "Search in" value for the server library only ("" is everything).
    static let searchInLibraryId = "library"
    /// Max time per server source when searching everywhere.
    static let searchAllTimeout: TimeInterval = 20

    /// Where to search: everything by default (also when the filter is absent, as in Aidoku's global search),
    /// the library, or one source still selected in the settings (a deselected one → everything).
    static func searchTarget(filters: [AidokuRunner.FilterValue], selectedIds: [String]) -> SuwayomiSearchTarget {
        guard let value = searchSourceId(filters: filters) else { return .all }
        if value == searchInLibraryId { return .library }
        return selectedIds.contains(value) ? .source(value) : .all
    }

    /// Library results first, then each source in order, skipping manga already listed (same server id).
    static func mergeSearchResults(library: [AidokuRunner.Manga], sources: [[AidokuRunner.Manga]]) -> [AidokuRunner.Manga] {
        var seen = Set<String>()
        return (library + sources.flatMap { $0 }).filter { seen.insert($0.key).inserted }
    }

    /// Sections of a grouped search: the library (when it found something), then every source that
    /// answered, in order (pending: everything in one library section).
    static func groupedSections(
        library: [AidokuRunner.Manga],
        sources: [(source: SuwayomiServerSource, entries: [AidokuRunner.Manga]?)],
        baseUrl: URL,
        libraryTitle: String
    ) -> [GroupedSearchSection] {
        [.init(id: searchInLibraryId, title: libraryTitle, iconUrl: nil, entries: library + sources.flatMap { $0.entries ?? [] })]
    }

    /// A server icon path («/api/v1/extension/icon/…») as a URL on the server (pending).
    static func iconUrl(_ path: String?, baseUrl: URL) -> URL? {
        nil
    }

    /// Runs `operation`, failing with a timeout after `seconds`.
    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SourceError.networkError
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SourceError.networkError }
            return result
        }
    }

    /// First listing, always present: the server library (what the source showed before).
    static func libraryListing() -> AidokuRunner.Listing {
        .init(id: libraryListingId, name: NSLocalizedString("LIBRARY"), kind: .default)
    }

    struct RemoteFetchPlan: Equatable, Sendable {
        var fetchManga: Bool
        var fetchChapters: Bool

        var isEmpty: Bool { !fetchManga && !fetchChapters }
    }

    /// What the server has to fetch from the origin before the manga can be read.
    /// - details: only while the manga isn't `initialized` (never fetched);
    /// - chapters: when none are stored and the server doesn't keep them updated itself
    ///   (not initialized, or not in the server library).
    static func remoteFetchPlan(
        _ response: SuwayomiMangaUpdateResponse,
        needsDetails: Bool,
        needsChapters: Bool
    ) -> RemoteFetchPlan {
        let manga = response.data.manga
        // servers without the field: fall back to "no details at all"
        let initialized = manga.initialized ?? (manga.description != nil || manga.author != nil)
        let inLibrary = manga.inLibrary ?? false
        return .init(
            fetchManga: !initialized && (needsDetails || needsChapters),
            fetchChapters: needsChapters && response.chapterNodes.isEmpty && (!initialized || !inLibrary)
        )
    }

    /// Readable message from a GraphQL error: the server prepends
    /// "Exception while fetching data (/field) : " and appends a stack trace.
    static func readableMessage(_ message: String) -> String {
        var text = message.components(separatedBy: .newlines).first ?? message
        if let range = text.range(of: ") : "), text.hasPrefix("Exception while fetching data") {
            text = String(text[range.upperBound...])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "null" ? NSLocalizedString("SUWAYOMI_SERVER_ERROR") : text
    }

    /// The first GraphQL error of a response as a readable `SourceError`, if there is one.
    static func graphQLError(from data: Data) -> SourceError? {
        guard
            let response = try? JSONDecoder().decode(SuwayomiGraphQLErrorResponse.self, from: data),
            let message = response.errors.first?.message
        else {
            return nil
        }
        return .message(readableMessage(message))
    }

    static func isNoChaptersFound(_ error: Error) -> Bool {
        if case let .message(message) = error as? SourceError {
            return message.localizedCaseInsensitiveContains("No chapters found")
        }
        return false
    }
}
