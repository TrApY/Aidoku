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
        .init(
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
}

actor SuwayomiSourceRunner: Runner {
    static let sourceKeyPrefix = "suwayomi"

    let sourceKey: String
    let helper: SuwayomiHelper

    let features: SourceFeatures = .init(
        providesListings: true,
        dynamicFilters: true,
        dynamicSettings: true,
        dynamicListings: true,
        providesImageRequests: true,
        providesBaseUrl: true,
        handlesNotifications: true,
        handlesBasicLogin: true
    )

    private var name: String
    private var server: String
    /// Last list of server sources that could be offered (used if the server stops answering).
    private var serverSourcesCache: [SuwayomiServerSource]?

    init(sourceKey: String, name: String, server: String, transport: SuwayomiHelper.Transport? = nil) {
        self.sourceKey = sourceKey
        self.helper = if let transport {
            .init(sourceKey: sourceKey, transport: transport)
        } else {
            .init(sourceKey: sourceKey)
        }
        self.name = name
        self.server = server
    }

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

        let baseUrl = try helper.getConfiguredServer()
        if let serverSourceId = SuwayomiServerSources.searchSourceId(filters: filters, selectedIds: selectedServerSourceIds()) {
            // searching an installed source: the library filters don't apply
            let response: SuwayomiFetchSourceMangaResponse = try await helper.request(
                body: SuwayomiServerSources.searchPayload(sourceId: serverSourceId, query: query, page: page),
                timeout: SuwayomiServerSources.fetchTimeout
            )
            return SuwayomiServerSources.mangaPage(response, sourceKey: sourceKey, baseUrl: baseUrl)
        }
        let searchFilter = getSearchFilter(query: query, filters: filters)
        let response: SuwayomiMangaResponse = try await helper.request(body: Payload(variables: .init(
            filter: searchFilter.filter,
            orderBy: searchFilter.serverSort?.orderBy,
            orderByType: searchFilter.serverSort?.orderByType
        )))
        let nodes = sort(response.data.mangas.nodes, sort: searchFilter.localSort) // todo
        let entries = nodes.compactMap { $0.intoManga(sourceKey: sourceKey, baseUrl: baseUrl) }

        return .init(entries: entries, hasNextPage: false)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        guard let mangaId = Int(manga.key) else { throw SourceError.message("INVALID_KEY") }

        struct Payload: Encodable {
            let variables: Variables
            let query = """
                query GetMangaUpdate($mangaId: Int!) {
                  manga(id: $mangaId) {
                    artist
                    author
                    description
                    id
                    initialized
                    inLibrary
                    status
                    thumbnailUrl
                    title
                    url
                    genre
                    realUrl
                  }
                  chapters(condition: {mangaId: $mangaId}, orderBy: SOURCE_ORDER, orderByType: DESC) {
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
            }
        }

        let baseUrl = try helper.getConfiguredServer()
        var response: SuwayomiMangaUpdateResponse = try await helper.request(
            body: Payload(variables: .init(mangaId: mangaId))
        )
        let plan = SuwayomiServerSources.remoteFetchPlan(response, needsDetails: needsDetails, needsChapters: needsChapters)
        if !plan.isEmpty {
            // manga only browsed from a server source: the server hasn't fetched it from the origin yet
            let result = await fetchFromOrigin(mangaId: mangaId, plan: plan)
            if result.fetchedSomething {
                response = try await helper.request(body: Payload(variables: .init(mangaId: mangaId)))
            } else if let error = result.error, plan.fetchManga, response.data.chapters.nodes.isEmpty {
                // never fetched and nothing stored to fall back on
                throw error
            }
        }

        var manga = manga
        if needsDetails, let updatedManga = response.data.manga.intoManga(sourceKey: sourceKey, baseUrl: baseUrl) {
            manga = manga.copy(from: updatedManga)
        }
        if needsChapters {
            manga.chapters = response.data.chapters.nodes.map {
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
        if listing.id == SuwayomiServerSources.libraryListingId {
            // the server library, as the search without text nor filters
            return try await getSearchMangaList(query: nil, page: page, filters: [])
        }
        guard let payload = SuwayomiServerSources.listingPayload(listingId: listing.id, page: page) else {
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
        // the library always comes first (the source opens on it); server sources are optional
        let serverSources = (try? await selectedServerSources(timeout: SuwayomiServerSources.sourcesTimeout)) ?? []
        return [SuwayomiServerSources.libraryListing()] + SuwayomiServerSources.listings(for: serverSources)
    }

    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        guard let url = URL(string: url) else { throw SourceError.message("INVALID_URL") }
        var request = URLRequest(url: url)
        helper.authorize(request: &request)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    func getSettings() async throws -> [Setting] {
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
        // installed server sources; hidden if the server doesn't answer
        if
            let sources = try? await fetchServerSources(timeout: SuwayomiServerSources.sourcesTimeout),
            let setting = SuwayomiServerSources.setting(sources: sources)
        {
            settings.append(setting)
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
                    Task {
                        await updateSourceConfig()
                    }
                }

            default:
                break
        }
    }

    /// Sources installed on the server that can be offered (no local source, NSFW per app setting).
    private func fetchServerSources(timeout: TimeInterval? = nil) async throws -> [SuwayomiServerSource] {
        let response: SuwayomiSourcesResponse = try await helper.request(body: SuwayomiServerSourcesPayload(), timeout: timeout)
        let allowNsfw = SuwayomiServerSources.allowsNsfw(contentRatings: AppSettings.browse.contentRatings.get())
        let sources = SuwayomiServerSources.available(response.data.sources.nodes, allowNsfw: allowNsfw)
        serverSourcesCache = sources
        return sources
    }

    /// Server sources chosen in the settings, in the settings order.
    private func selectedServerSourceIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: SuwayomiServerSources.defaultsKey(sourceKey: sourceKey)) ?? []
    }

    private func selectedServerSources(timeout: TimeInterval? = nil) async throws -> [SuwayomiServerSource] {
        let ids = selectedServerSourceIds()
        guard !ids.isEmpty else { return [] }
        let sources: [SuwayomiServerSource]
        do {
            sources = try await fetchServerSources(timeout: timeout)
        } catch {
            guard let serverSourcesCache else { throw error }
            sources = serverSourcesCache
        }
        return SuwayomiServerSources.selected(ids: ids, from: sources)
    }

    /// Asks the server to fetch a manga and/or its chapters from the origin website.
    /// Failures are logged, not thrown: the caller falls back on what the server already has.
    private func fetchFromOrigin(
        mangaId: Int,
        plan: SuwayomiServerSources.RemoteFetchPlan
    ) async -> (fetchedSomething: Bool, error: Error?) {
        var fetchedSomething = false
        var firstError: Error?
        if plan.fetchManga {
            do {
                let _: SuwayomiFetchMangaResponse = try await helper.request(
                    body: SuwayomiFetchMangaPayload(variables: .init(id: mangaId)),
                    timeout: SuwayomiServerSources.fetchTimeout
                )
                fetchedSomething = true
            } catch {
                LogManager.logger.error("Suwayomi fetchManga \(mangaId) failed: \(error)")
                firstError = error
            }
        }
        if plan.fetchChapters {
            do {
                let _: SuwayomiFetchChaptersResponse = try await helper.request(
                    body: SuwayomiFetchChaptersPayload(variables: .init(mangaId: mangaId)),
                    timeout: SuwayomiServerSources.fetchTimeout
                )
                fetchedSomething = true
            } catch where SuwayomiServerSources.isNoChaptersFound(error) {
                // the origin has no chapters: an empty list, not an error
            } catch {
                LogManager.logger.error("Suwayomi fetchChapters \(mangaId) failed: \(error)")
                firstError = firstError ?? error
            }
        }
        return (fetchedSomething, firstError)
    }

    private func updateSourceConfig(updateSourceList: Bool = false) async {
        let config = CustomSourceConfig.suwayomi(.init(key: sourceKey, name: name, server: server))
        await SourceManager.shared.updateCustomSource(key: sourceKey, config: config, updateSourceList: updateSourceList)
    }
}

// MARK: Search Filters
extension SuwayomiSourceRunner {
    func getSearchFilters() async throws -> [AidokuRunner.Filter] {
        async let categories = getCategories()
        async let tags = getTags()
        async let serverSources = try? selectedServerSources(timeout: SuwayomiServerSources.sourcesTimeout)

        let categoryItems = try await categories
        let tagItems = try await tags

        var filters: [AidokuRunner.Filter] = []
        if let searchIn = SuwayomiServerSources.searchInFilter(sources: await serverSources ?? []) {
            filters.append(searchIn)
        }
        filters += [
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
