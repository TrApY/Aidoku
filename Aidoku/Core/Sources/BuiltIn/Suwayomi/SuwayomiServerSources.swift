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

enum SuwayomiServerSources {
    /// Id of the server's built-in local source, never offered.
    static let localSourceId = "0"
    /// Fetching from the origin websites can be slow.
    static let fetchTimeout: TimeInterval = 90
    /// Searching one server source.
    static let searchSourceTimeout: TimeInterval = 30
    /// Listing the installed sources must not block settings or listings when the server is down.
    static let sourcesTimeout: TimeInterval = 10

    /// SUWA-34: while true, `getMangaUpdate` of the Suwayomi runner asks the server to look for new chapters on
    /// the scan's website even when it already has some stored. Set by the user's pull to refresh (library and
    /// manga page) with `withOriginFetch(forced:_:)`; only the Suwayomi runner reads it, the source protocol
    /// is untouched.
    @TaskLocal static var forceOriginFetch = false

    /// Runs `operation` with `forceOriginFetch` set to `forced`.
    static func withOriginFetch<T>(forced: Bool, _ operation: () async throws -> T) async rethrows -> T {
        try await operation()
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

    /// Parses a listing id created by `childListings(for:)`.
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

    /// A server icon path («/api/v1/extension/icon/…») as a URL on the server (as the covers).
    static func iconUrl(_ path: String?, baseUrl: URL) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: baseUrl)?.absoluteURL
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
    ///   (not initialized, or not in the server library), or always when `forceChapters` (SUWA-34).
    static func remoteFetchPlan(
        _ response: SuwayomiMangaUpdateResponse,
        needsDetails: Bool,
        needsChapters: Bool,
        forceChapters: Bool = false
    ) -> RemoteFetchPlan {
        let manga = response.data.manga
        // servers without the field: fall back to "no details at all"
        let initialized = manga.initialized ?? (manga.description != nil || manga.author != nil)
        let inLibrary = manga.inLibrary ?? false
        return .init(
            fetchManga: !initialized && (needsDetails || needsChapters),
            fetchChapters: needsChapters && (forceChapters || (response.chapterNodes.isEmpty && (!initialized || !inLibrary)))
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
