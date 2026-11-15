//
//  MangaSourceNoticeTests.swift
//  AidokuTests
//
//  The notice of a manga page whose source isn't installed.
//

import Testing
@testable import Aidoku

struct MangaSourceNoticeTests {
    @Test func shownForAnyMangaWithoutItsSourceOnceTheSourcesAreLoaded() {
        // in the library: Migrar, and WebView if it has a web page
        #expect(MangaSourceNotice.make(sourcesLoaded: true, hasSource: false, inLibrary: true, hasWebUrl: true) == .init(migrate: true, webView: true))
        // not in the library (opened from the history, a link…): only WebView
        #expect(MangaSourceNotice.make(sourcesLoaded: true, hasSource: false, inLibrary: false, hasWebUrl: true) == .init(migrate: false, webView: true))
        #expect(MangaSourceNotice.make(sourcesLoaded: true, hasSource: false, inLibrary: false, hasWebUrl: false) == .init(migrate: false, webView: false))
        // with its source: no notice
        #expect(MangaSourceNotice.make(sourcesLoaded: true, hasSource: true, inLibrary: true, hasWebUrl: true) == nil)
        // the installed sources are still loading: nothing yet (no flicker)
        #expect(MangaSourceNotice.make(sourcesLoaded: false, hasSource: false, inLibrary: true, hasWebUrl: true) == nil)
    }
}
