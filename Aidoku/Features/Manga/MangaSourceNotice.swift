//
//  MangaSourceNotice.swift
//  Aidoku
//
//  The notice of a manga page whose source isn't installed: what it offers.
//

import Foundation

struct MangaSourceNotice: Equatable {
    /// «Migrar» (only for a library entry).
    var migrate: Bool
    /// «WebView» (the manga has a web page).
    var webView: Bool

    /// nil: no notice (the source is there, or the installed sources are still loading: no flicker).
    static func make(sourcesLoaded: Bool, hasSource: Bool, inLibrary: Bool, hasWebUrl: Bool) -> MangaSourceNotice? {
        // pending: as before, only for library entries and without waiting for the sources
        guard !hasSource, inLibrary else { return nil }
        return .init(migrate: true, webView: hasWebUrl)
    }
}
