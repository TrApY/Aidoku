//
//  GlobalSearch.swift
//  Aidoku
//
//  Rows of the global search and of the migration search: one per source (each source installed on a
//  Suwayomi server is a source of its own).
//

import AidokuRunner
import Foundation

/// A row of results: one source.
struct GlobalSearchRow: Identifiable, Equatable {
    let source: AidokuRunner.Source
    let result: AidokuRunner.MangaPageResult
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
        if failed { return .failed }
        return result.entries.isEmpty ? .noResults : .results
    }

    var id: String { source.id }
    var title: String { source.name }
    var imageUrl: URL? { source.imageUrl }

    static func == (lhs: GlobalSearchRow, rhs: GlobalSearchRow) -> Bool {
        lhs.id == rhs.id
    }
}

enum GlobalSearch {
    /// The row of one source for `query`; a source that fails keeps its row, as «No respondió» (as Tachimanga).
    static func rows(for source: AidokuRunner.Source, query: String) async -> [GlobalSearchRow] {
        do {
            let result = try await source.getSearchMangaList(query: query, page: 1, filters: [])
            return [.init(source: source, result: result)]
        } catch {
            LogManager.logger.warn("Search in \(source.key) failed: \(error)")
            return [.init(source: source, result: .init(entries: [], hasNextPage: false), failed: true)]
        }
    }

    /// The rows without the manga being migrated.
    static func excluding(_ mangaId: MangaIdentifier, from rows: [GlobalSearchRow]) -> [GlobalSearchRow] {
        rows.map { row in
            .init(
                source: row.source,
                result: .init(entries: row.result.entries.filter { $0.identifier != mangaId }, hasNextPage: row.result.hasNextPage),
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

    /// What a bulk migration picks for `manga` among the rows of the target sources, never `manga` itself:
    /// first the rows of a source other than the manga's own, then its own source; in each group the same
    /// normalized title before the first result.
    static func bestMatch(for manga: AidokuRunner.Manga, rows: [GlobalSearchRow]) -> AidokuRunner.Manga? {
        let notItself: (AidokuRunner.Manga) -> Bool = { $0.identifier != manga.identifier }
        let title = normalizedTitle(manga.title)
        let others = rows.filter { $0.source.key != manga.sourceKey }
        let own = rows.filter { $0.source.key == manga.sourceKey }
        for group in [others, own] {
            let candidates = group.flatMap(\.result.entries).filter(notItself)
            if let match = candidates.first(where: { normalizedTitle($0.title) == title }) ?? candidates.first {
                return match
            }
        }
        return nil
    }

    /// The target sources of a bulk migration in the order they are tried for `manga`: its own source last
    /// (a match in another source is preferred).
    static func targetOrder(_ sources: [AidokuRunner.Source], for manga: AidokuRunner.Manga) -> [AidokuRunner.Source] {
        sources.filter { $0.key != manga.sourceKey } + sources.filter { $0.key == manga.sourceKey }
    }
}
