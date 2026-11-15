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
    /// The source didn't answer (failed or too slow).
    var failed = false

    var isLibrary: Bool { id == SuwayomiServerSources.searchInLibraryId }
    /// The server source the entries come from (nil for the library: any of them).
    var serverSourceId: String? { isLibrary ? nil : id }
}

/// A source whose search covers several server sources and can give the results of each one apart.
protocol GroupedSearchRunner: Sendable {
    /// The library section (if it found something) and one section per server source a search covers
    /// (the marked ones first), also those without results or that didn't answer (`failed`).
    func groupedSearch(query: String) async throws -> [GroupedSearchSection]
    /// The server source of a manga of this source (nil if unknown).
    func serverSourceId(ofMangaKey mangaKey: String) async -> String?
}

/// A row of results: a whole source, or one section of a grouped source.
struct GlobalSearchRow: Identifiable, Equatable {
    let source: AidokuRunner.Source
    let result: AidokuRunner.MangaPageResult
    var section: GroupedSearchSection?
    /// The source didn't answer (failed or too slow).
    var failed = false

    enum Status: Equatable {
        case results
        /// «Sin resultados»
        case noResults
        /// «No respondió»
        case failed
    }

    var status: Status {
        if failed || section?.failed == true { return .failed }
        return result.entries.isEmpty ? .noResults : .results
    }

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
    /// The rows of one source for `query`; a source that fails keeps its row, as «No respondió» (as Tachimanga).
    static func rows(for source: AidokuRunner.Source, query: String) async -> [GlobalSearchRow] {
        if let grouped = source.runner as? GroupedSearchRunner {
            do {
                return rows(source: source, sections: try await grouped.groupedSearch(query: query))
            } catch {
                LogManager.logger.warn("Grouped search in \(source.key) failed: \(error)")
                return [.init(source: source, result: .init(entries: [], hasNextPage: false), failed: true)]
            }
        }
        do {
            let result = try await source.getSearchMangaList(query: query, page: 1, filters: [])
            return [.init(source: source, result: result)]
        } catch {
            LogManager.logger.warn("Search in \(source.key) failed: \(error)")
            return [.init(source: source, result: .init(entries: [], hasNextPage: false), failed: true)]
        }
    }

    /// One row per section, in order (empty ones say «Sin resultados», failed ones «No respondió»).
    static func rows(source: AidokuRunner.Source, sections: [GroupedSearchSection]) -> [GlobalSearchRow] {
        sections.map {
            .init(source: source, result: .init(entries: $0.entries, hasNextPage: false), section: $0)
        }
    }

    /// The rows without the manga being migrated (a library row left empty goes: it only shows results).
    static func excluding(_ mangaId: MangaIdentifier, from rows: [GlobalSearchRow]) -> [GlobalSearchRow] {
        rows.compactMap { row in
            let entries = row.result.entries.filter { $0.identifier != mangaId }
            if entries.isEmpty, row.section?.isLibrary == true { return nil }
            return .init(
                source: row.source,
                result: .init(entries: entries, hasNextPage: row.result.hasNextPage),
                section: row.section.map { .init(id: $0.id, title: $0.title, iconUrl: $0.iconUrl, entries: entries, failed: $0.failed) },
                failed: row.failed
            )
        }
    }

    /// Lowercase, without accents nor signs or spaces («Crónicas: ¡Demoníaca!» → «cronicasdemoniaca»).
    static func normalizedTitle(_ title: String) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es"))
            .lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// What a bulk migration picks for `manga` among the rows of one target source, never `manga` itself.
    /// With server sources (Suwayomi): first the rows of a server source other than the old manga's (any
    /// server source when it is unknown), then the rest (library, its own source); in each group the same
    /// normalized title before the first result. Other sources: the first result, as before.
    static func bestMatch(
        for manga: AidokuRunner.Manga,
        oldServerSourceId: String?,
        rows: [GlobalSearchRow]
    ) -> AidokuRunner.Manga? {
        let notItself: (AidokuRunner.Manga) -> Bool = { $0.identifier != manga.identifier }
        guard rows.contains(where: { $0.section != nil }) else {
            return rows.lazy.compactMap { $0.result.entries.first(where: notItself) }.first
        }
        let title = normalizedTitle(manga.title)
        let preferred = rows.filter { row in
            guard let id = row.serverSourceId else { return false }
            return id != oldServerSourceId
        }
        let rest = rows.filter { row in !preferred.contains(row) }
        for group in [preferred, rest] {
            let candidates = group.flatMap(\.result.entries).filter(notItself)
            if let match = candidates.first(where: { normalizedTitle($0.title) == title }) ?? candidates.first {
                return match
            }
        }
        return nil
    }
}
