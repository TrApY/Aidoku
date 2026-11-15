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

extension ChapterFlagMask {
    /// An order chosen on purpose (also the source's, descending, which has no other bit). SUWA-12 H5.
    static let sortChosen: Int = 1 << 10
}

/// The order of a manga: in the library, the one in its library flags (synced by iCloud); out of it, the
/// device's own; with none chosen, the last one chosen in any manga (as Tachimanga). SUWA-12 G2/H5.
enum ChapterSortMemory {
    static let defaultKey = "Manga.chapterSortDefault"

    static func key(_ mangaId: MangaIdentifier) -> String {
        "Manga.chapterSort.\(mangaId)"
    }

    /// The order in the library flags, if one was chosen (the bit, or an order other than the source's
    /// descending stored before the bit existed).
    static func chosen(inFlags flags: Int) -> ChapterSortChoice? {
        let stored = ChapterSortChoice(
            option: ChapterSortOption(flags: flags).rawValue,
            ascending: flags & ChapterFlagMask.sortAscending != 0
        )
        return flags & ChapterFlagMask.sortChosen != 0 || stored != .initial ? stored : nil
    }

    /// `flags` with the order and the «chosen» bit.
    static func flags(_ choice: ChapterSortChoice, into flags: Int) -> Int {
        var flags = flags & ~(ChapterFlagMask.sortAscending | ChapterFlagMask.sortMethod)
        if choice.ascending {
            flags |= ChapterFlagMask.sortAscending
        }
        flags |= choice.option << 1
        return flags | ChapterFlagMask.sortChosen
    }

    static func local(for mangaId: MangaIdentifier, defaults: UserDefaults = .standard) -> ChapterSortChoice? {
        decode(defaults.data(forKey: key(mangaId)))
    }

    static func forgetLocal(_ mangaId: MangaIdentifier, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(mangaId))
    }

    static func isChosen(for mangaId: MangaIdentifier, flags: Int, defaults: UserDefaults = .standard) -> Bool {
        chosen(inFlags: flags) != nil || local(for: mangaId, defaults: defaults) != nil
    }

    static func load(for mangaId: MangaIdentifier, flags: Int, defaults: UserDefaults = .standard) -> ChapterSortChoice {
        // the library flags first: a change on the other device wins over an old one here
        chosen(inFlags: flags) ?? local(for: mangaId, defaults: defaults) ?? decode(defaults.data(forKey: defaultKey)) ?? .initial
    }

    /// In the library the order goes to its flags (the caller saves them) and not to the device.
    static func record(
        _ choice: ChapterSortChoice,
        for mangaId: MangaIdentifier,
        inLibrary: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        if inLibrary {
            defaults.removeObject(forKey: key(mangaId))
        } else {
            defaults.set(data, forKey: key(mangaId))
        }
        defaults.set(data, forKey: defaultKey)
    }

    private static func decode(_ data: Data?) -> ChapterSortChoice? {
        data.flatMap { try? JSONDecoder().decode(ChapterSortChoice.self, from: $0) }
    }
}
