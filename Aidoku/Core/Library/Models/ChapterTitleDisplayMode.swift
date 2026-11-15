//
//  ChapterTitleDisplayMode.swift
//  Aidoku
//
//  Created by Skitty on 9/29/25.
//

import Foundation

enum ChapterTitleDisplayMode: Int, CaseIterable {
    case `default` = 0
    case chapter = 1
    case volume = 2
}

extension ChapterTitleDisplayMode {
    /// The mode stored for a manga (Komga sources keep their own setting): what counts as its highest read number.
    static func stored(for mangaId: MangaIdentifier) -> ChapterTitleDisplayMode {
        let key = "Manga.chapterDisplayMode.\(mangaId.description)"
        return if mangaId.sourceKey.hasPrefix(KomgaSourceRunner.sourceKeyPrefix) {
            UserDefaults.standard.bool(forKey: "\(mangaId.sourceKey).useChapters") ? .chapter : .volume
        } else {
            .init(rawValue: UserDefaults.standard.integer(forKey: key)) ?? .default
        }
    }

    var localizedTitle: String {
        switch self {
            case .default: NSLocalizedString("DISPLAY_DEFAULT")
            case .chapter: NSLocalizedString("DISPLAY_CHAPTER")
            case .volume: NSLocalizedString("DISPLAY_VOLUME")
        }
    }
}
