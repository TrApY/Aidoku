//
//  LibraryViewModel.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 7/25/22.
//

import AidokuRunner
import UIKit

@MainActor
class LibraryViewModel {
    var manga: [MangaInfo] = []
    var pinnedManga: [MangaInfo] = []
    var sourceKeys: [String] = []

    // temporary storage when searching
    private var searchQuery: String = ""
    private var storedManga: [MangaInfo]?
    private var storedPinnedManga: [MangaInfo]?

    enum PinType: String, CaseIterable {
        case none
        case unread
        case updatedChapters

        var title: String {
            switch self {
                case .none: NSLocalizedString("PIN_DISABLED")
                case .unread: NSLocalizedString("PIN_UNREAD")
                case .updatedChapters: NSLocalizedString("PIN_UPDATED_CHAPTERS")
            }
        }

        var needsUpdateOnContentOpen: Bool {
            switch self {
                case .none: false
                case .unread: false
                case .updatedChapters: true
            }
        }
    }

    enum SortMethod: Int, CaseIterable {
        case alphabetical = 0
        case lastRead
        case lastOpened
        case lastUpdated
        case dateAdded
        case lastChapter
        case unreadChapters
        case totalChapters

        var title: String {
            switch self {
                case .alphabetical: NSLocalizedString("SORT_TITLE")
                case .lastRead: NSLocalizedString("SORT_LAST_READ")
                case .lastOpened: NSLocalizedString("SORT_LAST_OPENED")
                case .lastUpdated: NSLocalizedString("SORT_LAST_UPDATED")
                case .dateAdded: NSLocalizedString("SORT_DATE_ADDED")
                case .lastChapter: NSLocalizedString("SORT_LATEST_CHAPTER")
                case .unreadChapters: NSLocalizedString("SORT_UNREAD_CHAPTERS")
                case .totalChapters: NSLocalizedString("SORT_TOTAL_CHAPTERS")
            }
        }

        var descendingTitle: String {
            switch self {
                case .alphabetical: NSLocalizedString("ASCENDING") // reverse default for alphabetical sort
                case .lastRead: NSLocalizedString("NEWEST_FIRST")
                case .lastOpened: NSLocalizedString("NEWEST_FIRST")
                case .lastUpdated: NSLocalizedString("NEWEST_FIRST")
                case .dateAdded: NSLocalizedString("NEWEST_FIRST")
                case .lastChapter: NSLocalizedString("NEWEST_FIRST")
                case .unreadChapters: NSLocalizedString("HIGHEST_FIRST")
                case .totalChapters: NSLocalizedString("HIGHEST_FIRST")
            }
        }

        var ascendingTitle: String {
            switch self {
                case .alphabetical: NSLocalizedString("DESCENDING")
                case .lastRead: NSLocalizedString("OLDEST_FIRST")
                case .lastOpened: NSLocalizedString("OLDEST_FIRST")
                case .lastUpdated: NSLocalizedString("OLDEST_FIRST")
                case .dateAdded: NSLocalizedString("OLDEST_FIRST")
                case .lastChapter: NSLocalizedString("OLDEST_FIRST")
                case .unreadChapters: NSLocalizedString("LOWEST_FIRST")
                case .totalChapters: NSLocalizedString("LOWEST_FIRST")
            }
        }

        /// The order the library query asks for.
        var querySort: LibraryQuery.Sort {
            switch self {
                case .alphabetical: .title
                case .lastRead: .lastRead
                case .lastOpened: .lastOpened
                case .lastUpdated: .lastUpdated
                case .dateAdded: .dateAdded
                case .lastChapter: .lastChapter
                case .unreadChapters: .unreadChapters
                case .totalChapters: .totalChapters
            }
        }
    }

    struct BadgeType: OptionSet {
        let rawValue: Int

        static let unread = BadgeType(rawValue: 1 << 0)
        static let downloaded = BadgeType(rawValue: 1 << 1)
    }

    lazy var pinType: PinType = getPinType()
    lazy var sortMethod = SortMethod(rawValue: AppSettings.library.sortOption.get()) ?? .lastOpened
    lazy var sortAscending = AppSettings.library.sortAscending.get()
    lazy var badgeType: BadgeType = {
        var type: BadgeType = []
        if AppSettings.library.unreadChapterBadges.get() {
            type.insert(.unread)
        }
        if AppSettings.library.downloadedChapterBadges.get() {
            type.insert(.downloaded)
        }
        return type
    }()

    var filters: [LibraryFilter] {
        didSet {
            saveFilters()
        }
    }
    var activeFilters: [LibraryFilter] {
        if let currentCategory, let group = filterGroups.first(where: { $0.title == currentCategory }) {
            group.filters + self.filters
        } else {
            self.filters
        }
    }

    var categories: [String] = []
    var filterGroups: [FilterGroup] = []
    lazy var currentCategory: String? = AppSettings.library.currentCategory.get() {
        didSet {
            AppSettings.library.currentCategory.set(currentCategory)
        }
    }
    var isInRealCategory: Bool {
        if let currentCategory, !currentCategory.isEmpty {
            categories.contains(currentCategory)
        } else {
            false
        }
    }
    var isInUncategorizedCategory: Bool {
        currentCategory?.isEmpty ?? false
    }
    private(set) var actuallyEmpty = true

    init() {
        let filtersData = AppSettings.library.filtersData.get()
        if let filtersData {
            let filters = try? JSONDecoder().decode([LibraryFilter].self, from: filtersData)
            self.filters = filters ?? []
        } else {
            self.filters = []
        }
    }
}

extension LibraryViewModel {
    func isCategoryLocked() -> Bool {
        guard AppSettings.library.lockLibrary.get() else { return false }
        if let currentCategory, !currentCategory.isEmpty {
            let lockedCategories = AppSettings.library.lockedCategories.get()
            return lockedCategories.contains(currentCategory)
        }
        return true
    }

    func getPinType() -> PinType {
        PinType(rawValue: AppSettings.library.pinTitles.get()) ?? .none
    }

    func reloadSettings() {
        sortMethod = SortMethod(rawValue: AppSettings.library.sortOption.get()) ?? .lastOpened
        sortAscending = AppSettings.library.sortAscending.get()
        if
            let data = AppSettings.library.filtersData.get(),
            let restoredFilters = try? JSONDecoder().decode([LibraryFilter].self, from: data),
            filters != restoredFilters
        {
            filters = restoredFilters
        }
    }

    func refreshCategories(skipDataLoad: Bool = false) async {
        // the categories and the filter groups in one read
        let snapshot = await DataRepositories.shared.categories.snapshot(of: nil, filterGroup: nil)
        let (loadedCategories, loadedGroups) = (snapshot.titles, snapshot.filterGroups)
        (categories, filterGroups) = (loadedCategories, loadedGroups)
        if !skipDataLoad {
            let isInFilterGroup = filterGroups.contains(where: { $0.title == currentCategory })
            let showUncategorized = AppSettings.library.showUncategorizedCategory.get()
            if let currentCategory, (!categories.contains(currentCategory) && !isInFilterGroup) || (currentCategory.isEmpty && !showUncategorized) {
                self.currentCategory = nil
                await loadLibrary()
            } else if isInFilterGroup {
                // refresh filter group in case filters changed
                await loadLibrary()
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func loadLibrary() async {
        // handle filter groups
        let filters = self.activeFilters
        let currentCategory = (isInUncategorizedCategory || isInRealCategory) ? self.currentCategory : nil

        let query = LibraryQuery(
            scope: currentCategory.map { $0.isEmpty ? .uncategorized : .category($0) } ?? .all,
            sort: sortMethod.querySort,
            // the title order is shown the other way round
            ascending: sortMethod == .alphabetical ? !sortAscending : sortAscending,
            filters: filters,
            pinUpdatedChapters: pinType == .updatedChapters
        )
        guard let page = await DataRepositories.shared.library.page(query) else { return }
        let (actuallyEmpty, pinnedManga, manga, sourceKeys, unappliedFilters) = (
            page.isEmpty, page.pinned, page.manga, page.sourceKeys, page.unappliedFilters
        )

        self.pinnedManga = pinnedManga
        self.manga = manga
        self.storedPinnedManga = nil
        self.storedManga = nil
        self.sourceKeys = sourceKeys.sorted()
        self.actuallyEmpty = actuallyEmpty

        await fetchUnreads(skipSortCheck: true)
        await fetchDownloadCounts()

        if !unappliedFilters.isEmpty {
            let filter: (MangaInfo) -> Bool = { info in
                for filter in unappliedFilters {
                    let condition: Bool
                    switch filter.type {
                        case .downloaded: condition = info.downloads > 0
                        case .hasUnread: condition = info.unread > 0
                        default: continue
                    }
                    let shouldSkip = filter.exclude ? condition : !condition
                    guard !shouldSkip else { return false }
                }
                return true
            }
            self.pinnedManga = self.pinnedManga.filter(filter)
            self.manga = self.manga.filter(filter)
        }

        if pinType == .unread {
            let currentManga = self.manga + self.pinnedManga
            var pinnedManga: [MangaInfo] = []
            var manga: [MangaInfo] = []
            for item in currentManga {
                if item.unread > 0 {
                    pinnedManga.append(item)
                } else {
                    manga.append(item)
                }
            }
            self.pinnedManga = pinnedManga
            self.manga = manga
        }

        if sortMethod == .unreadChapters {
            await sortLibrary()
        }

        if !searchQuery.isEmpty {
            await search(query: searchQuery)
        }
    }

    // updates unread counts and manga sort order for history change
    func updateHistory(for manga: [MangaInfo], read: Bool) async {
        let currentManga = self.manga + self.pinnedManga
        // the ones still shown, counted at once (each with its own filters)
        let shown = manga.compactMap { item in currentManga.first(where: { $0.id == item.id }) }
        let counts = await DataRepositories.shared.chapters.unreadCounts(of: shown.map(\.id))
        var unreadCounts: [Int: Int] = [:]
        for info in shown {
            unreadCounts[info.hashValue] = counts[info.id] ?? 0
        }
        await MainActor.run {
            for count in unreadCounts {
                if let pinnedIndex = pinnedManga.firstIndex(where: { $0.hashValue == count.key }) {
                    pinnedManga[pinnedIndex].unread = count.value
                    if read && sortMethod == .lastRead && pinnedIndex != 0 {
                        let manga = pinnedManga.remove(at: pinnedIndex)
                        pinnedManga.insert(manga, at: 0)
                    }
                } else if let mangaIndex = self.manga.firstIndex(where: { $0.hashValue == count.key }) {
                    self.manga[mangaIndex].unread = count.value
                    if read && sortMethod == .lastRead && mangaIndex != 0 {
                        let manga = self.manga.remove(at: mangaIndex)
                        self.manga.insert(manga, at: 0)
                    }
                }
            }
        }
        if pinType == .unread || activeFilters.contains(where: { $0.type == .hasUnread }) {
            await loadLibrary()
        } else if sortMethod == .unreadChapters {
            await sortLibrary()
        }
    }

    func fetchUnreads(skipSortCheck: Bool = false) async {
        if !skipSortCheck && pinType == .unread {
            // re-load library to ensure pinned manga is correct
            return await loadLibrary()
        }

        let currentManga = self.manga + self.pinnedManga

        // fetch new unread counts
        let counts = await DataRepositories.shared.chapters.unreadCounts(of: currentManga.map(\.id))
        var unreadCounts: [Int: Int] = [:]
        for manga in currentManga {
            unreadCounts[manga.hashValue] = counts[manga.id] ?? 0
        }

        // set unread counts
        for (i, manga) in self.manga.enumerated() {
            guard let count = unreadCounts[manga.hashValue] else { continue }
            self.manga[i].unread = count
        }
        for (i, manga) in self.pinnedManga.enumerated() {
            guard let count = unreadCounts[manga.hashValue] else { continue }
            self.pinnedManga[i].unread = count
        }

        // re-sort library if needed
        if !skipSortCheck && sortMethod == .unreadChapters {
            await sortLibrary()
        }
    }

    func fetchUnreads(for identifier: MangaIdentifier) async {
        let unreadCount = await DataRepositories.shared.chapters.unreadCount(of: identifier)
        var didUpdate = false
        if let index = self.manga.firstIndex(where: { $0.id == identifier }) {
            if self.manga[index].unread != unreadCount {
                didUpdate = true
                self.manga[index].unread = unreadCount
            }
        } else if let index = self.pinnedManga.firstIndex(where: { $0.id == identifier }) {
            if self.pinnedManga[index].unread != unreadCount {
                didUpdate = true
                self.pinnedManga[index].unread = unreadCount
            }
        }
        // re-sort library if needed
        if didUpdate {
            if pinType == .unread {
                await loadLibrary()
            } else if sortMethod == .unreadChapters {
                await sortLibrary()
            }
        }
    }

    func fetchDownloadCounts(for identifier: MangaIdentifier? = nil) async {
        var downloadCounts: [MangaIdentifier: Int] = [:]
        if let identifier {
            downloadCounts[identifier] = await DownloadManager.shared.downloadsCount(for: identifier)
        } else {
            let currentManga = self.manga + self.pinnedManga
            for manga in currentManga {
                let identifier = manga.id
                downloadCounts[identifier] = await DownloadManager.shared.downloadsCount(for: identifier)
            }
        }
        for (i, manga) in self.pinnedManga.enumerated() {
            if let count = downloadCounts[manga.id] {
                self.pinnedManga[i].downloads = count
            }
        }
        for (i, manga) in self.manga.enumerated() {
            if let count = downloadCounts[manga.id] {
                self.manga[i].downloads = count
            }
        }
    }

    @MainActor
    func sortLibrary() async {
        switch sortMethod {
            case .alphabetical:
                if sortAscending {
                    pinnedManga.sort { $0.title ?? "" > $1.title ?? "" }
                    manga.sort { $0.title ?? "" > $1.title ?? "" }
                } else {
                    pinnedManga.sort { $0.title ?? "" < $1.title ?? "" }
                    manga.sort { $0.title ?? "" < $1.title ?? "" }
                }

            case .unreadChapters:
                if sortAscending {
                    pinnedManga.sort {
                        if $0.unread == 0 {
                            false
                        } else if $1.unread == 0 {
                            true
                        } else {
                            $0.unread < $1.unread
                        }
                    }
                    manga.sort {
                        if $0.unread == 0 {
                            false
                        } else if $1.unread == 0 {
                            true
                        } else {
                            $0.unread < $1.unread
                        }
                    }
                } else {
                    pinnedManga.sort { $0.unread > $1.unread }
                    manga.sort { $0.unread > $1.unread }
                }

            default:
                await loadLibrary()
        }
    }

    func setSort(method: SortMethod, ascending: Bool) async {
        guard sortMethod != method || sortAscending != ascending else {
            return
        }
        if sortAscending != ascending {
            sortAscending = ascending
            AppSettings.library.sortAscending.set(sortAscending)
        }
        if sortMethod != method {
            sortMethod = method
            AppSettings.library.sortOption.set(sortMethod.rawValue)
        }
        await sortLibrary()
    }

    func toggleFilter(method: LibraryFilter.FilterMethod, value: String? = nil) async {
        let filterIndex = filters.firstIndex(where: { $0.type == method && $0.value == value })
        if let filterIndex {
            if filters[filterIndex].exclude {
                filters.remove(at: filterIndex)
            } else {
                filters[filterIndex].exclude = true
            }
        } else {
            filters.append(LibraryFilter(type: method, value: value, exclude: false))
        }
        await loadLibrary()
    }

    private func saveFilters() {
        let filtersData = try? JSONEncoder().encode(filters)
        if let filtersData {
            AppSettings.library.filtersData.set(filtersData)
        }
    }

    func search(query: String) async {
        searchQuery = query

        guard !query.isEmpty else {
            var shouldResort = false
            if let storedManga {
                manga = storedManga
                self.storedManga = nil
                shouldResort = true
            }
            if let storedPinnedManga {
                pinnedManga = storedPinnedManga
                self.storedPinnedManga = nil
                shouldResort = true
            }
            if shouldResort {
                await sortLibrary()
            }
            return
        }
        if storedManga == nil {
            storedManga = manga
            storedPinnedManga = pinnedManga
        }
        guard let storedManga, let storedPinnedManga else {
            return
        }

        let query = query.lowercased()
        pinnedManga = storedPinnedManga.filter { $0.title?.lowercased().contains(query) ?? false }
        manga = storedManga.filter { $0.title?.lowercased().fuzzyMatch(query) ?? false || $0.author?.lowercased().fuzzyMatch(query) ?? false }
    }

    // returns true if library was reloaded
    @discardableResult
    func mangaOpened(mangaId: MangaIdentifier) async -> Bool {
        guard sortMethod == .lastOpened || pinType.needsUpdateOnContentOpen else { return false }

        var libraryReloaded = false

        let pinnedIndex = pinnedManga.firstIndex(where: { $0.id == mangaId })
        if let pinnedIndex {
            if sortMethod == .lastOpened {
                let manga = pinnedManga.remove(at: pinnedIndex)
                if pinType.needsUpdateOnContentOpen {
                    self.manga.insert(manga, at: 0)
                } else {
                    pinnedManga.insert(manga, at: 0)
                }
            } else {
                await loadLibrary() // don't know where to put in manga array, just refresh
                libraryReloaded = true
            }
        } else if sortMethod == .lastOpened {
            let index = manga.firstIndex(where: { $0.id == mangaId })
            if let index {
                let manga = manga.remove(at: index)
                if sortAscending {
                    // add to end
                    self.manga.append(manga)
                } else {
                    // add to start
                    self.manga.insert(manga, at: 0)
                }
            }
        }

        return libraryReloaded
    }

    /// Several manga read since the last refresh (oldest first): one reload at most.
    func mangaRead(mangaIds: [MangaIdentifier]) async {
        if activeFilters.contains(where: { $0.type == .hasUnread }) {
            await loadLibrary()
            return
        }
        for mangaId in mangaIds {
            await mangaRead(mangaId: mangaId)
        }
    }

    func mangaRead(mangaId: MangaIdentifier) async {
        if activeFilters.contains(where: { $0.type == .hasUnread }) {
            // reload library in case all chapters were read and the manga should be filtered
            await loadLibrary()
            return
        }

        guard sortMethod == .lastRead else { return }

        if let pinnedIndex = pinnedManga.firstIndex(where: { $0.id == mangaId }) {
            let manga = pinnedManga.remove(at: pinnedIndex)
            if pinType == .updatedChapters {
                self.manga.insert(manga, at: sortAscending ? self.manga.count : 0)
            } else {
                pinnedManga.insert(manga, at: sortAscending ? pinnedManga.count : 0)
            }
        } else if let index = manga.firstIndex(where: { $0.id == mangaId }) {
            let manga = manga.remove(at: index)
            self.manga.insert(manga, at: sortAscending ? self.manga.count : 0)
        }
    }

    func removeFromLibrary(manga: MangaInfo) async {
        pinnedManga.removeAll { $0.id == manga.id }
        self.manga.removeAll { $0.id == manga.id }
        await MangaManager.shared.removeFromLibrary(mangaId: manga.id)
    }

    func removeFromLibrary(mangaIds: [MangaIdentifier]) async {
        let set = Set(mangaIds)
        pinnedManga.removeAll { set.contains($0.id) }
        self.manga.removeAll { set.contains($0.id) }
        await MangaManager.shared.removeFromLibrary(mangaIds: mangaIds)
    }

    func addToCurrentCategory(manga: MangaInfo) async {
        guard let currentCategory, isInRealCategory else { return }
        await DataRepositories.shared.categories.assign([manga.id], add: [currentCategory])
    }

    func removeFromCurrentCategory(manga: MangaInfo) async {
        guard let currentCategory, isInRealCategory else { return }
        pinnedManga.removeAll { $0.id == manga.id }
        self.manga.removeAll { $0.id == manga.id }
        await DataRepositories.shared.categories.remove([currentCategory], from: manga.id)
    }
}
