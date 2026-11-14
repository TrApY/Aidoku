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
struct SuwayomiServerSource: Decodable, Sendable, Hashable {
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

/// Skeleton: signatures only, behaviour pending (tests must fail).
enum SuwayomiServerSources {
    static let localSourceId = "0"
    static let settingKey = "serverSources"
    static let searchInFilterId = "searchIn"
    static let fetchTimeout: TimeInterval = 90

    static func defaultsKey(sourceKey: String) -> String { "" }
    static func allowsNsfw(contentRatings: Set<AidokuRunner.SourceContentRating>) -> Bool { false }
    static func available(_ sources: [SuwayomiServerSource], allowNsfw: Bool) -> [SuwayomiServerSource] { [] }
    static func selected(ids: [String], from available: [SuwayomiServerSource]) -> [SuwayomiServerSource] { [] }
    static func listings(for sources: [SuwayomiServerSource]) -> [AidokuRunner.Listing] { [] }
    static func parseListingId(_ id: String) -> (type: SuwayomiFetchSourceMangaType, sourceId: String)? { nil }
    static func listingPayload(listingId: String, page: Int) -> SuwayomiFetchSourceMangaPayload? { nil }
    static func searchPayload(sourceId: String, query: String?, page: Int) -> SuwayomiFetchSourceMangaPayload {
        .init(variables: .init(source: "", type: .search, page: 0, query: nil))
    }
    static func searchSourceId(filters: [AidokuRunner.FilterValue]) -> String? { nil }
    static func searchInFilter(sources: [SuwayomiServerSource]) -> AidokuRunner.Filter? { nil }
    static func setting(sources: [SuwayomiServerSource]) -> AidokuRunner.Setting? { nil }
    static func mangaPage(_ response: SuwayomiFetchSourceMangaResponse, sourceKey: String, baseUrl: URL) -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }
    static func needsRemoteFetch(_ response: SuwayomiMangaUpdateResponse, needsDetails: Bool, needsChapters: Bool) -> Bool { false }
    static func readableMessage(_ message: String) -> String { message }
    static func graphQLError(from data: Data) -> SourceError? { nil }
    static func isNoChaptersFound(_ error: Error) -> Bool { false }
}
