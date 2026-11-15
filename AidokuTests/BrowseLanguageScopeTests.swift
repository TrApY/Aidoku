//
//  BrowseLanguageScopeTests.swift
//  AidokuTests
//
//  SUWA-12 D M2: the language filter never hides a source with library manga (Explorar, global search),
//  and an empty list because of it says so.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

struct BrowseLanguageScopeTests {
    private func info(_ key: String, _ name: String, _ languages: [String]) -> Aidoku.SourceInfo {
        Aidoku.SourceInfo(sourceId: key, name: name, languages: languages, version: 1, contentRating: .safe)
    }

    @Test func aSourceWithLibraryMangaIsSearchedWhateverItsLanguage() {
        #expect(BrowseLanguages.shows(languages: ["es"], sourceKey: "suwa.olympus", active: ["en"], inLibrary: ["suwa.olympus"]))
        #expect(!BrowseLanguages.shows(languages: ["es"], sourceKey: "suwa.emperor", active: ["en"], inLibrary: ["suwa.olympus"]))
        #expect(BrowseLanguages.shows(languages: ["en"], sourceKey: "aidoku.en", active: ["en"], inLibrary: []))
    }

    @Test func aSourceWithLibraryMangaIsListedInItsLanguage() {
        let groups = BrowseSourceGroups.make(
            installed: [info("suwa.olympus", "Olympus", ["es"]), info("suwa.emperor", "Emperor", ["es"]), info("aidoku.en", "English", ["en"])],
            pinnedKeys: [],
            recents: [:],
            active: ["en"],
            inLibrary: ["suwa.olympus"],
            localCode: "en"
        )
        #expect(groups.languages.map(\.code) == ["en", "es"])
        #expect(groups.languages.last?.sources.map(\.sourceId) == ["suwa.olympus"])
    }

    @Test func theSourcesWithLibraryMangaAreRead() async throws {
        let store = try ConversionStore()
        defer { store.close() }
        let context = store.container.newBackgroundContext()
        try context.performAndWait {
            for (sourceId, id, library) in [("suwa.olympus", "1", true), ("suwa.olympus", "2", true), ("suwa.emperor", "3", false)] {
                let object = store.insert("Manga", [
                    "sourceId": sourceId, "id": id, "title": "Manga \(id)", "neverUpdate": false, "chapterFlags": Int16(0),
                    "editedKeys": Int32(0), "nsfw": Int16(0), "status": Int16(0), "viewer": Int16(0)
                ], in: context)
                if library {
                    store.insert("LibraryManga", ["dateAdded": Date(), "manga": object], in: context)
                }
            }
            try context.save()
        }
        #expect(await LibrarySourceKeys.load(container: store.container) == ["suwa.olympus"])
    }

    @Test func emptyBecauseOfTheLanguagesSaysSo() {
        #expect(BrowseEmptyState.make(shown: 0, installed: 3, isSearching: false) == .filteredOut)
        #expect(BrowseEmptyState.make(shown: 0, installed: 0, isSearching: false) == .noSources)
        #expect(BrowseEmptyState.make(shown: 2, installed: 3, isSearching: false) == .hidden)
        #expect(BrowseEmptyState.make(shown: 0, installed: 3, isSearching: true) == .hidden)
    }
}
