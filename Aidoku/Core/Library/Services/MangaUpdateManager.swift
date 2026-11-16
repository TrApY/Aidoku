//
//  MangaUpdateManager.swift
//  Aidoku
//
//  Created by axiel7 on 17/03/2024.
//

import AidokuRunner
import Foundation

struct MangaUpdateManager {
    static let shared = MangaUpdateManager()
}

extension MangaUpdateManager {
    func viewAllUpdates(of manga: AidokuRunner.Manga) async {
        let updates = await DataRepositories.shared.mangaUpdates.markViewed(of: manga.identifier)
        if !updates.isEmpty {
            // on the main thread (it was posted from the context's queue before)
            await MainActor.run {
                NotificationCenter.default.post(name: .mangaUpdatesViewed, object: updates)
            }
        }
    }
}
