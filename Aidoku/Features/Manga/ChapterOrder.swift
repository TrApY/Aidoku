//
//  ChapterOrder.swift
//  Aidoku
//
//  SUWA-12 G: «Marcar anteriores» by the source's order (not the screen's), and the chapter order each
//  manga remembers, with the last one chosen as the default for the rest.
//

import AidokuRunner
import Foundation

enum ChapterOrder {
    /// The chapters before `chapter`: a smaller number when both have one, otherwise later in the source
    /// order (sources list the newest first). Whatever the order and the filters on screen.
    static func previous(of chapter: AidokuRunner.Chapter, inSourceOrder chapters: [AidokuRunner.Chapter]) -> [AidokuRunner.Chapter] {
        guard let position = chapters.firstIndex(where: { $0.key == chapter.key }) else { return [] }
        let number = chapter.chapterNumber.flatMap { $0 >= 0 ? $0 : nil }
        return chapters.enumerated().compactMap { index, other in
            guard other.key != chapter.key else { return nil }
            if let number, let otherNumber = other.chapterNumber, otherNumber >= 0 {
                return otherNumber < number ? other : nil
            }
            return index > position ? other : nil
        }
    }
}

struct ChapterSortChoice: Codable, Equatable, Sendable {
    var option: Int
    var ascending: Bool

    static let initial = ChapterSortChoice(option: ChapterSortOption.sourceOrder.rawValue, ascending: false)
}

/// Each manga keeps its order on the device (also out of the library); the last order chosen in any
/// manga is the default for those without one (as Tachimanga). A library entry's stored flags still count.
enum ChapterSortMemory {
    static let defaultKey = "Manga.chapterSortDefault"

    static func key(_ mangaId: MangaIdentifier) -> String {
        "Manga.chapterSort.\(mangaId)"
    }

    static func load(for mangaId: MangaIdentifier, flags: Int, defaults: UserDefaults = .standard) -> ChapterSortChoice {
        ChapterSortChoice(option: ChapterSortOption(flags: flags).rawValue, ascending: flags & ChapterFlagMask.sortAscending != 0) // pendiente[G2#1]
    }

    static func record(_ choice: ChapterSortChoice, for mangaId: MangaIdentifier, defaults: UserDefaults = .standard) {
         // pendiente[G2#2]
    }

    private static func decode(_ data: Data?) -> ChapterSortChoice? {
        data.flatMap { try? JSONDecoder().decode(ChapterSortChoice.self, from: $0) }
    }
}
