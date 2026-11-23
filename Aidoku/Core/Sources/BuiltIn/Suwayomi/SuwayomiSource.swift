//
//  SuwayomiSource.swift
//  Aidoku
//
//  Created by skitty on 7/1/26.
//

import AidokuRunner
import Foundation
import UIKit

extension AidokuRunner.Source {
    static func suwayomi(
        key: String = "suwayomi",
        name: String,
        server: String
    ) -> AidokuRunner.Source {
        SuwayomiConnections.shared.register(connection: key)
        return .init(
            url: nil,
            key: key,
            name: name,
            version: 1,
            languages: ["multi"],
            urls: UserDefaults.standard.string(forKey: "\(key).server")
                .flatMap { URL(string: $0) }
                .flatMap { [$0] } ?? [],
            contentRating: .safe,
            config: .init(
                languageSelectType: .single,
                supportsTagSearch: true
            ),
            staticListings: [],
            staticFilters: [
                .init(
                    id: "author",
                    title: NSLocalizedString("AUTHOR"),
                    value: .text(placeholder: NSLocalizedString("AUTHOR_NAME"))
                ),
                .init(
                    id: "artist",
                    title: NSLocalizedString("AUTHOR"),
                    value: .text(placeholder: NSLocalizedString("ARTIST_NAME"))
                )
            ],
            staticSettings: [],
            runner: SuwayomiSourceRunner(sourceKey: key, name: name, server: server)
        )
    }

    /// A source installed on the server, as an Aidoku source of its own: its listings and search only
    /// cover that server source; the server and the login are the parent's.
    static func suwayomiServerSource(_ config: SuwayomiServerSourceConfig) -> AidokuRunner.Source {
        SuwayomiConnections.shared.register(child: config)
        let server = UserDefaults.standard.string(forKey: "\(config.parentKey).server") ?? ""
        return .init(
            url: nil,
            key: config.key,
            name: config.name,
            version: 1,
            languages: config.languages,
            urls: URL(string: server).map { [$0] } ?? [],
            contentRating: config.contentRating,
            imageUrl: SuwayomiServerSourceIcons.storedIconUrl(sourceKey: config.key),
            config: .init(supportsAuthorSearch: false, supportsTagSearch: false),
            staticListings: SuwayomiServerSources.childListings(for: config),
            staticFilters: [],
            staticSettings: [],
            runner: SuwayomiSourceRunner(sourceKey: config.key, name: config.name, server: server, serverSource: config)
        )
    }
}

actor SuwayomiSourceRunner: Runner {
    static let sourceKeyPrefix = "suwayomi"

    /// The identity of the source (stamped on its manga).
    let sourceKey: String
    /// Server and login: the connection's (the parent's for a server source).
    let helper: SuwayomiHelper
    /// Set for a source installed on the server (a child): listings and search only cover it.
    let serverSource: SuwayomiServerSourceConfig?

    let features: SourceFeatures

    private var name: String
    private var server: String
    /// Categories and tags for the filters are asked again after this time.
    private let filterCacheMaxAge: TimeInterval
    private var filterCache: (categories: [FilterItem], tags: [FilterItem], at: Date)?

    init(
        sourceKey: String,
        name: String,
        server: String,
        serverSource: SuwayomiServerSourceConfig? = nil,
        transport: SuwayomiHelper.Transport? = nil,
        filterCacheMaxAge: TimeInterval = 10 * 60,
        searchLimiter: SuwayomiSearchLimiter? = nil
    ) {
        self.sourceKey = sourceKey
        self.serverSource = serverSource
        self.filterCacheMaxAge = filterCacheMaxAge
        self.helper = if let transport {
            .init(sourceKey: sourceKey, transport: transport)
        } else {
            .init(sourceKey: sourceKey)
        }
        self.searchLimiter = searchLimiter ?? SuwayomiSearchLimiter.shared(for: helper.sourceKey)
        self.name = name
        self.server = server
        self.features = if serverSource != nil {
            .init(providesListings: true, providesImageRequests: true, providesBaseUrl: true)
        } else {
            .init(
                providesListings: true,
                dynamicFilters: true,
                dynamicSettings: true,
                dynamicListings: true,
                providesImageRequests: true,
                providesBaseUrl: true,
                handlesNotifications: true,
                handlesBasicLogin: true
            )
        }
    }

    /// At most 4 searches at a time against the server (all the sources of a server are one server).
    private let searchLimiter: SuwayomiSearchLimiter

    private enum SortOption: CaseIterable {
        case unreadChapters
        case totalChapters
        case title
        case dateAdded
        case recentlyRead
        case latestFetchedChapter
        case latestUploadedChapter

        var title: String {
            switch self {
                case .unreadChapters: NSLocalizedString("SORT_UNREAD_CHAPTERS")
                case .totalChapters: NSLocalizedString("SORT_TOTAL_CHAPTERS")
                case .title: NSLocalizedString("SORT_TITLE")
                case .dateAdded: NSLocalizedString("SORT_DATE_ADDED")
                case .recentlyRead: NSLocalizedString("SORT_LAST_READ")
                case .latestFetchedChapter: NSLocalizedString("SORT_LAST_UPDATED")
                case .latestUploadedChapter: NSLocalizedString("SORT_CHAPTER_ADDED")
            }
        }

        var serverOrder: SuwayomiMangaOrderBy? {
            switch self {
                case .title: .title
                case .dateAdded: .inLibraryAt
                case .latestFetchedChapter: .lastFetchedAt
                default: nil
            }
        }
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        let baseUrl = try helper.getConfiguredServer()
        if let serverSource {
            // a server source: its own search (without text, its popular list)
            let response: SuwayomiFetchSourceMangaResponse = try await searchLimiter.run { [helper] in
                try await helper.request(
                    body: SuwayomiServerSources.searchPayload(sourceId: serverSource.serverSourceId, query: query, page: page),
                    timeout: SuwayomiServerSources.searchSourceTimeout
                )
            }
            return SuwayomiServerSources.mangaPage(response, sourceKey: sourceKey, baseUrl: baseUrl)
        }
        // the connection: the server library (it is not offered as a source, but its manga still open)
        return .init(entries: try await searchLibrary(query: query, filters: filters, baseUrl: baseUrl), hasNextPage: false)
    }

    /// The server library, with the library filters (categories, status, tags, sort).
    private func searchLibrary(query: String?, filters: [AidokuRunner.FilterValue], baseUrl: URL) async throws -> [AidokuRunner.Manga] {
        struct Payload: Encodable {
            let variables: Variables
            let query = """
                query SearchManga($filter: MangaFilterInput, $orderBy: MangaOrderBy, $orderByType: SortOrder) {
                  mangas(condition: {inLibrary: true}, filter: $filter, orderBy: $orderBy, orderByType: $orderByType) {
                    nodes {
                      artist
                      author
                      id
                      inLibraryAt
                      thumbnailUrl
                      title
                      chapters {
                        totalCount
                      }
                      latestUploadedChapter {
                        uploadDate
                      }
                      latestFetchedChapter {
                        fetchedAt
                      }
                      lastReadChapter {
                        lastReadAt
                      }
                      unreadCount
                      downloadCount
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let filter: SuwayomiMangaFilterInput?
                let orderBy: SuwayomiMangaOrderBy?
                let orderByType: SuwayomiSortOrder?
            }
        }

        let searchFilter = getSearchFilter(query: query, filters: filters)
        let response: SuwayomiMangaResponse = try await helper.request(body: Payload(variables: .init(
            filter: searchFilter.filter,
            orderBy: searchFilter.serverSort?.orderBy,
            orderByType: searchFilter.serverSort?.orderByType
        )))
        let nodes = sort(response.data.mangas.nodes, sort: searchFilter.localSort) // todo
        return nodes.compactMap { $0.intoManga(sourceKey: sourceKey, baseUrl: baseUrl) }
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        guard let mangaId = Int(manga.key) else { throw SourceError.message("INVALID_KEY") }

        struct Payload: Encodable {
            let variables: Variables
            // only what the caller needs: details and/or chapters (the state fields decide remote fetches)
            let query = """
                query GetMangaUpdate($mangaId: Int!, $details: Boolean!, $chapters: Boolean!) {
                  manga(id: $mangaId) {
                    id
                    initialized
                    inLibrary
                    artist @include(if: $details)
                    author @include(if: $details)
                    description @include(if: $details)
                    status @include(if: $details)
                    thumbnailUrl @include(if: $details)
                    title @include(if: $details)
                    url @include(if: $details)
                    genre @include(if: $details)
                    realUrl @include(if: $details)
                  }
                  chapters(condition: {mangaId: $mangaId}, orderBy: SOURCE_ORDER, orderByType: DESC) @include(if: $chapters) {
                    nodes {
                      id
                      url
                      chapterNumber
                      name
                      uploadDate
                      scanlator
                      sourceOrder
                      mangaId
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let mangaId: Int
                let details: Bool
                let chapters: Bool
            }
        }

        let baseUrl = try helper.getConfiguredServer()
        var response: SuwayomiMangaUpdateResponse = try await helper.request(
            body: Payload(variables: .init(mangaId: mangaId, details: needsDetails, chapters: needsChapters))
        )
        let plan = SuwayomiServerSources.remoteFetchPlan(
            response,
            needsDetails: needsDetails,
            needsChapters: needsChapters,
            forceChapters: SuwayomiServerSources.forceOriginFetch
        )
        if !plan.isEmpty {
            // manga only browsed from a server source: the server hasn't fetched it from the origin yet
            let result = await fetchFromOrigin(mangaId: mangaId, plan: plan)
            // ask again only for what was asked for and just fetched
            let detailsAgain = needsDetails && result.mangaFetched
            let chaptersAgain = needsChapters && result.chaptersFetched
            if detailsAgain || chaptersAgain {
                let newer: SuwayomiMangaUpdateResponse = try await helper.request(
                    body: Payload(variables: .init(mangaId: mangaId, details: detailsAgain, chapters: chaptersAgain))
                )
                response = response.updated(with: newer, details: detailsAgain, chapters: chaptersAgain)
            }
            if !needsChapters || response.chapterNodes.isEmpty {
                if needsChapters, let error = result.chaptersError {
                    // chapters asked, none stored and the fetch failed: not the same as «no chapters»
                    throw error
                }
                if !result.mangaFetched && !result.chaptersFetched, let error = result.mangaError {
                    // never fetched and nothing stored to fall back on
                    throw error
                }
            }
        }

        var manga = manga
        if needsDetails, let updatedManga = response.data.manga.intoManga(sourceKey: sourceKey, baseUrl: baseUrl) {
            manga = manga.copy(from: updatedManga)
        }
        if needsChapters {
            manga.chapters = response.chapterNodes.map {
                $0.intoChapter(baseUrl: baseUrl)
            }
        }
        return manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        guard let chapterId = Int(chapter.key) else { throw SourceError.message("INVALID_KEY") }

        struct Payload: Encodable {
            let variables: Variables
            let query = """
                mutation GetPages($chapterId: Int!) {
                  fetchChapterPages(input: {chapterId: $chapterId}) {
                    pages
                  }
                }
                """

            struct Variables: Encodable {
                let chapterId: Int
            }
        }

        let baseUrl = try helper.getConfiguredServer()
        let response: SuwayomiPagesResponse = try await helper.request(
            body: Payload(variables: .init(chapterId: chapterId))
        )
        return response.data.fetchChapterPages.pages.compactMap {
            URL(string: $0, relativeTo: baseUrl).map { .init(content: .url(url: $0)) }
        }
    }

    func getMangaList(listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        if serverSource == nil {
            // the server library, as the library search without text nor filters
            let baseUrl = try helper.getConfiguredServer()
            return .init(entries: try await searchLibrary(query: nil, filters: [], baseUrl: baseUrl), hasNextPage: false)
        }
        guard
            let payload = SuwayomiServerSources.listingPayload(listingId: listing.id, page: page),
            payload.variables.source == serverSource?.serverSourceId // only its own lists
        else {
            return .init(entries: [], hasNextPage: false)
        }
        let baseUrl = try helper.getConfiguredServer()
        let response: SuwayomiFetchSourceMangaResponse = try await helper.request(
            body: payload,
            timeout: SuwayomiServerSources.fetchTimeout
        )
        return SuwayomiServerSources.mangaPage(response, sourceKey: sourceKey, baseUrl: baseUrl)
    }

    func getListings() async throws -> [AidokuRunner.Listing] {
        if let serverSource {
            return SuwayomiServerSources.childListings(for: serverSource)
        }
        // the connection: only the server library (each server source is a source of its own)
        return [SuwayomiServerSources.libraryListing()]
    }

    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        guard let url = URL(string: url) else { throw SourceError.message("INVALID_URL") }
        var request = URLRequest(url: url)
        helper.authorize(request: &request)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    func getSettings() async throws -> [Setting] {
        guard serverSource == nil else { return [] }
        var settings: [Setting] = [
            .init(
                title: "SOURCE_NAME",
                value: .group(.init(
                    footer: "SOURCE_NAME_INFO",
                    items: [
                        .init(
                            key: "name",
                            notification: "name_change",
                            value: .text(.init(
                                placeholder: NSLocalizedString("SUWAYOMI"),
                                returnKeyType: UIReturnKeyType.done.rawValue,
                                autocorrectionDisabled: true,
                                defaultValue: name
                            ))
                        )
                    ]
                ))
            ),
            .init(
                title: "SERVER_URL",
                value: .group(.init(
                    footer: "SERVER_URL_INFO",
                    items: [
                        .init(
                            key: "server",
                            notification: "server_change",
                            refreshes: ["settings", "content"],
                            value: .text(.init(
                                placeholder: "http://127.0.0.1:4567",
                                autocapitalizationType: UITextAutocapitalizationType.none.rawValue,
                                keyboardType: UIKeyboardType.URL.rawValue,
                                returnKeyType: UIReturnKeyType.done.rawValue,
                                autocorrectionDisabled: true,
                                defaultValue: server
                            ))
                        )
                    ]
                ))
            )
        ]
        let isLoggedIn = UserDefaults.standard.value(forKey: "\(sourceKey).login") != nil
        var shouldShowLoginSetting = isLoggedIn
        if !shouldShowLoginSetting {
            let loginType = try await helper.getLoginType()
            if let loginType {
                shouldShowLoginSetting = loginType != .none
            }
        }
        if shouldShowLoginSetting {
            settings.append(contentsOf: [
                .init(
                    value: .group(.init(
                        items: [
                            .init(
                                key: "login",
                                title: "LOGIN",
                                notification: "login",
                                requires: "server",
                                refreshes: ["settings", "content", "listings", "filters"],
                                value: .login(.init(method: .basic))
                            )
                        ]
                    ))
                )
            ])
        }
        return settings
    }

    func getBaseUrl() async throws -> URL? {
        try helper.getConfiguredServer()
    }

    func handleBasicLogin(key _: String, username: String, password: String) async throws -> Bool {
        let server = try helper.getConfiguredServer()

        guard let response = await SuwayomiHelper.checkLogin(server: server, username: username, password: password) else {
            return false
        }

        if let cookie = response.cookie {
            UserDefaults.standard.setValue(cookie, forKey: "\(sourceKey).cookie")
        }
        if let accessToken = response.accessToken, let refreshToken = response.refreshToken {
            UserDefaults.standard.setValue(accessToken, forKey: "\(sourceKey).token")
            UserDefaults.standard.setValue(refreshToken, forKey: "\(sourceKey).refreshToken")
        }

        return true
    }

    func handleNotification(notification: String) async throws {
        // clear additional login values when logging out
        switch notification {
            case "login":
                let isLoggedIn = UserDefaults.standard.value(forKey: "\(sourceKey).login") != nil
                if !isLoggedIn {
                    UserDefaults.standard.removeObject(forKey: "\(sourceKey).cookie")
                    UserDefaults.standard.removeObject(forKey: "\(sourceKey).token")
                    UserDefaults.standard.removeObject(forKey: "\(sourceKey).refreshToken")
                }

            case "name_change":
                let key = "\(sourceKey).name"
                let newValue = UserDefaults.standard.string(forKey: key) ?? ""

                // ensure normalized value
                let normalizedValue = newValue.trimmingCharacters(in: .whitespaces)
                if newValue != normalizedValue {
                    UserDefaults.standard.set(normalizedValue, forKey: key)
                    return // the function will be called again with the new value
                }

                if newValue != name {
                    // update db source config with new name
                    name = newValue
                    Task {
                        await updateSourceConfig(updateSourceList: true)
                    }
                }

            case "server_change":
                let key = "\(sourceKey).server"
                let newValue = UserDefaults.standard.string(forKey: key) ?? ""

                // ensure normalized value
                let normalizedValue = (newValue.last == "/" ? String(newValue[..<newValue.index(before: newValue.endIndex)]) : newValue)
                    .trimmingCharacters(in: .whitespaces)
                if newValue != normalizedValue {
                    UserDefaults.standard.set(normalizedValue, forKey: key)
                    return // the function will be called again with the new value
                }

                if newValue != server {
                    // update db source config with new server url
                    server = newValue
                    filterCache = nil
                    // another server: its library marks are not the old one's
                    TrackerManager.suwayomi.markedInLibrary.removeAll(withPrefix: "\(sourceKey)|")
                    for child in SuwayomiConnections.shared.children(of: sourceKey) {
                        TrackerManager.suwayomi.markedInLibrary.removeAll(withPrefix: "\(child.key)|")
                    }
                    Task {
                        await updateSourceConfig()
                    }
                }

            default:
                break
        }
    }

    /// Asks the server to fetch a manga and/or its chapters from the origin website.
    /// Failures are logged, not thrown: the caller falls back on what the server already has.
    private func fetchFromOrigin(
        mangaId: Int,
        plan: SuwayomiServerSources.RemoteFetchPlan
    ) async -> (mangaFetched: Bool, chaptersFetched: Bool, mangaError: Error?, chaptersError: Error?) {
        var mangaFetched = false
        var chaptersFetched = false
        var mangaError: Error?
        var chaptersError: Error?
        if plan.fetchManga {
            do {
                let _: SuwayomiFetchMangaResponse = try await helper.request(
                    body: SuwayomiFetchMangaPayload(variables: .init(id: mangaId)),
                    timeout: SuwayomiServerSources.fetchTimeout
                )
                mangaFetched = true
            } catch {
                LogManager.logger.error("Suwayomi fetchManga \(mangaId) failed: \(error)")
                mangaError = error
            }
        }
        if plan.fetchChapters {
            do {
                let _: SuwayomiFetchChaptersResponse = try await helper.request(
                    body: SuwayomiFetchChaptersPayload(variables: .init(mangaId: mangaId)),
                    timeout: SuwayomiServerSources.fetchTimeout
                )
                chaptersFetched = true
            } catch where SuwayomiServerSources.isNoChaptersFound(error) {
                // the origin has no chapters: an empty list, not an error
            } catch {
                LogManager.logger.error("Suwayomi fetchChapters \(mangaId) failed: \(error)")
                chaptersError = error
            }
        }
        return (mangaFetched, chaptersFetched, mangaError, chaptersError)
    }

    private func updateSourceConfig(updateSourceList: Bool = false) async {
        guard serverSource == nil else { return }
        let config = CustomSourceConfig.suwayomi(.init(key: sourceKey, name: name, server: server))
        await SourceManager.shared.updateCustomSource(key: sourceKey, config: config, updateSourceList: updateSourceList)
    }
}

// MARK: Search Filters
extension SuwayomiSourceRunner {
    func getSearchFilters() async throws -> [AidokuRunner.Filter] {
        // a server source has no filters of its own (each extension's filters are out of scope)
        guard serverSource == nil else { return [] }
        let (categoryItems, tagItems) = try await filterData()

        var filters: [AidokuRunner.Filter] = [
            .init(
                id: "sort",
                title: NSLocalizedString("SORT"),
                value: .sort(
                    canAscend: true,
                    options: SuwayomiSourceRunner.SortOption.allCases.map(\.title),
                    defaultValue: .init(index: 3, ascending: false)
                )
            ),
            .init(
                id: "status",
                title: NSLocalizedString("STATUS"),
                value: .multiselect(.init(
                    canExclude: true,
                    options: SuwayomiMangaStatus.allCases.map(\.title),
                    ids: SuwayomiMangaStatus.allCases.map(\.rawValue)
                ))
            )
        ]

        if categoryItems.count > 1 {
            filters.append(
                .init(
                    id: "category",
                    title: NSLocalizedString("CATEGORY"),
                    value: .select(.init(
                        options: [NSLocalizedString("ALL"), NSLocalizedString("NONE")] + categoryItems.map(\.title),
                        ids: ["", "0"] + categoryItems.map(\.id)
                    ))
                )
            )
        }

        if !tagItems.isEmpty {
            filters.append(
                .init(
                    id: "genre",
                    title: NSLocalizedString("TAG"),
                    value: .multiselect(.init(
                        isGenre: true,
                        canExclude: true,
                        usesTagStyle: true,
                        options: tagItems.map(\.title),
                        ids: tagItems.map(\.id)
                    ))
                )
            )
        }

        return filters
    }

    private struct SearchFilter {
        let filter: SuwayomiMangaFilterInput?
        let serverSort: (orderBy: SuwayomiMangaOrderBy, orderByType: SuwayomiSortOrder)?
        let localSort: (option: SortOption, ascending: Bool)?
    }

    private func getSearchFilter(query: String?, filters: [AidokuRunner.FilterValue]) -> SearchFilter {
        var filterInput: [SuwayomiMangaFilterInput] = []
        var sortOption = SortOption.allCases[3]
        var sortAscending = false

        if let query, !query.isEmpty {
            filterInput.append(.init(or: [
                .init(title: .includesInsensitive(query)),
                .init(url: .includesInsensitive(query)),
                .init(artist: .includesInsensitive(query)),
                .init(author: .includesInsensitive(query)),
                .init(description: .includesInsensitive(query))
            ]))
        }

        for filter in filters {
            switch filter {
                case let .text(id, value):
                    switch id {
                        case "author": filterInput.append(.init(author: .includesInsensitive(value)))
                        case "artist": filterInput.append(.init(artist: .includesInsensitive(value)))
                        default: break
                    }
                case let .sort(value):
                    sortOption = SortOption.allCases[safe: Int(value.index)] ?? sortOption
                    sortAscending = value.ascending
                case let .select(id, value):
                    switch id {
                        case "category":
                            filterInput.append(.init(
                                categoryId: value == "0"
                                    ? .isNull(true)
                                    : Int(value).flatMap { .equalTo($0) }
                            ))
                        case "genre":
                            filterInput.append(.init(genre: .includesInsensitive(value)))
                        default:
                            break
                    }
                case let .multiselect(id, included, excluded):
                    switch id {
                        case "status":
                            let included = included.compactMap(SuwayomiMangaStatus.init)
                            let excluded = excluded.compactMap(SuwayomiMangaStatus.init)
                            if !included.isEmpty {
                                filterInput.append(.init(status: .in(included)))
                            }
                            if !excluded.isEmpty {
                                filterInput.append(.init(status: .notEqualToAny(excluded)))
                            }
                        case "genre":
                            filterInput.append(contentsOf: included.map {
                                .init(genre: .includesInsensitive($0))
                            })
                            filterInput.append(contentsOf: excluded.map {
                                .init(genre: .notIncludesInsensitive($0))
                            })
                        default:
                            break
                    }
                default:
                    continue
            }
        }

        let filter = filterInput.isEmpty ? nil : SuwayomiMangaFilterInput(and: filterInput)
        let serverSort = sortOption.serverOrder.map { ($0, sortAscending ? SuwayomiSortOrder.asc : .desc) }
        let localSort = sortOption.serverOrder == nil ? (sortOption, sortAscending) : nil
        return .init(filter: filter, serverSort: serverSort, localSort: localSort)
    }

    private func sort(_ nodes: [SuwayomiMangaNode], sort: (option: SortOption, ascending: Bool)?) -> [SuwayomiMangaNode] {
        guard let sort else { return nodes }
        let result = switch sort.option {
            case .totalChapters:
                nodes.sorted { ($0.chapters?.totalCount ?? 0) < ($1.chapters?.totalCount ?? 0) }
            case .latestUploadedChapter:
                nodes.sorted {
                    ($0.latestUploadedChapter?.uploadDate.flatMap(Int.init) ?? 0) < ($1.latestUploadedChapter?.uploadDate.flatMap(Int.init) ?? 0)
                }
            case .recentlyRead:
                nodes.sorted { ($0.lastReadChapter?.lastReadAt.flatMap(Int.init) ?? 0) < ($1.lastReadChapter?.lastReadAt.flatMap(Int.init) ?? 0) }
            case .unreadChapters:
                nodes.sorted { ($0.unreadCount ?? 0) < ($1.unreadCount ?? 0) }
            default:
                nodes
        }
        return sort.ascending ? result : Array(result.reversed())
    }

    struct FilterItem {
        let id: String
        let title: String
    }

    /// Categories and library tags, kept `filterCacheMaxAge` (opening the filters doesn't ask each time).
    private func filterData() async throws -> (categories: [FilterItem], tags: [FilterItem]) {
        if let filterCache, Date().timeIntervalSince(filterCache.at) < filterCacheMaxAge {
            return (filterCache.categories, filterCache.tags)
        }
        let requestedServer = server
        async let categories = getCategories()
        async let tags = getTags()
        let result = try await (categories: categories, tags: tags)
        if server == requestedServer {
            filterCache = (result.categories, result.tags, Date())
        }
        return result
    }

    private func getCategories() async throws -> [FilterItem] {
        struct Payload: Encodable {
            let variables = Variables()
            let query = """
                query GetCategories($orderBy: CategoryOrderBy, $orderByType: SortOrder) {
                  categories(orderBy: $orderBy, orderByType: $orderByType) {
                    nodes {
                      id
                      name
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let orderBy = "ORDER"
                let orderByType = "ASC"
            }
        }

        let response: SuwayomiCategoryResponse = try await helper.request(body: Payload())
        return response.data.categories.nodes.map {
            .init(id: String($0.id), title: $0.name)
        }
    }

    private func getTags() async throws -> [FilterItem] {
        struct Payload: Encodable {
            let query = """
                query GetMangaTags {
                  mangas(condition: {inLibrary: true}) {
                    nodes {
                      genre
                    }
                  }
                }
                """
        }

        let response: SuwayomiMangaResponse = try await helper.request(body: Payload())
        return response.data.mangas.nodes
            .flatMap { $0.genre ?? [] }
            .unique()
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { .init(id: $0, title: $0) }
    }
}
