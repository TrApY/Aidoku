//
//  GlobalSearch.swift
//  Aidoku
//
//  Rows of the global search and of the migration search: one per source, or one per server source
//  for a source that searches several at once (Suwayomi).
//

import AidokuRunner
import Foundation

/// One part of a grouped search: a source installed on a server, or the server library.
struct GroupedSearchSection: Sendable, Equatable {
    /// The server source id, or `SuwayomiServerSources.searchInLibraryId` for the library.
    let id: String
    let title: String
    let iconUrl: URL?
    let entries: [AidokuRunner.Manga]

    var isLibrary: Bool { id == SuwayomiServerSources.searchInLibraryId }
    /// The server source the entries come from (nil for the library: any of them).
    var serverSourceId: String? { isLibrary ? nil : id }
}

/// A source whose search covers several server sources and can give the results of each one apart.
protocol GroupedSearchRunner: Sendable {
    /// The library section (if it found something) and one section per server source that answered, in
    /// the settings order. Sources that fail or take too long are left out.
    func groupedSearch(query: String) async throws -> [GroupedSearchSection]
    /// The server source of a manga of this source (nil if unknown).
    func serverSourceId(ofMangaKey mangaKey: String) async -> String?
}

/// A row of results: a whole source, or one section of a grouped source.
struct GlobalSearchRow: Identifiable, Equatable {
    let source: AidokuRunner.Source
    let result: AidokuRunner.MangaPageResult
    var section: GroupedSearchSection?

    var id: String {
        if let section {
            "\(source.id)#\(section.id)"
        } else {
            source.id
        }
    }

    var title: String { section?.title ?? source.name }
    var imageUrl: URL? { section.map(\.iconUrl) ?? source.imageUrl }
    var serverSourceId: String? { section?.serverSourceId }

    static func == (lhs: GlobalSearchRow, rhs: GlobalSearchRow) -> Bool {
        lhs.id == rhs.id
    }
}

enum GlobalSearch {
    /// The rows of one source for `query` (none if it fails).
    static func rows(for source: AidokuRunner.Source, query: String) async -> [GlobalSearchRow] {
        if let grouped = source.runner as? GroupedSearchRunner {
            do {
                return rows(source: source, sections: try await grouped.groupedSearch(query: query))
            } catch {
                LogManager.logger.warn("Grouped search in \(source.key) failed: \(error)")
                return []
            }
        }
        guard let result = try? await source.getSearchMangaList(query: query, page: 1, filters: []) else {
            return []
        }
        return [.init(source: source, result: result)]
    }

    /// One row per section (pending).
    static func rows(source: AidokuRunner.Source, sections: [GroupedSearchSection]) -> [GlobalSearchRow] {
        [.init(source: source, result: .init(entries: sections.flatMap(\.entries), hasNextPage: false))]
    }

    /// The rows without the manga being migrated (pending).
    static func excluding(_ mangaId: MangaIdentifier, from rows: [GlobalSearchRow]) -> [GlobalSearchRow] {
        rows
    }

    /// Lowercase, without accents nor signs or spaces (pending).
    static func normalizedTitle(_ title: String) -> String {
        title
    }

    /// What a bulk migration picks for `manga` among the rows of one target source (pending: the first).
    static func bestMatch(
        for manga: AidokuRunner.Manga,
        oldServerSourceId: String?,
        rows: [GlobalSearchRow]
    ) -> AidokuRunner.Manga? {
        rows.lazy.compactMap(\.result.entries.first).first
    }
}
