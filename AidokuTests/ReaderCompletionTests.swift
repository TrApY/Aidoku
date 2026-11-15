//
//  ReaderCompletionTests.swift
//  AidokuTests
//
//  SUWA-12 H1: a reader marks the chapter completed only with its end really on screen and the app in
//  the foreground.
//

import Foundation
import Testing

@testable import Aidoku

@Suite struct ReaderCompletionTests {
    // MARK: webtoon / continuous, when the scroll stops

    @Test func aGapBetweenPagesMidChapterDoesNotComplete() {
        // nothing under the bottom edge (the 15 pt between pages, or sizes still changing), page 20 of 38
        #expect(!ReaderCompletion.webtoonReachedEnd(
            bottomEdgePage: nil, maxVisiblePage: 20, totalPages: 38, transitionVisible: false, inForeground: true
        ))
    }

    @Test func theLastPageOnScreenCompletes() {
        #expect(ReaderCompletion.webtoonReachedEnd(
            bottomEdgePage: 38, maxVisiblePage: 38, totalPages: 38, transitionVisible: false, inForeground: true
        ))
    }

    @Test func theTransitionAfterTheLastPageCompletes() {
        #expect(ReaderCompletion.webtoonReachedEnd(
            bottomEdgePage: 39, maxVisiblePage: nil, totalPages: 38, transitionVisible: true, inForeground: true
        ))
    }

    @Test func noPagesKnownDoesNotComplete() {
        #expect(!ReaderCompletion.webtoonReachedEnd(
            bottomEdgePage: nil, maxVisiblePage: nil, totalPages: 0, transitionVisible: false, inForeground: true
        ))
        #expect(!ReaderCompletion.webtoonReachedEnd(
            bottomEdgePage: nil, maxVisiblePage: nil, totalPages: 0, transitionVisible: true, inForeground: true
        ))
    }

    @Test func inTheBackgroundTheWebtoonDoesNotComplete() {
        #expect(!ReaderCompletion.webtoonReachedEnd(
            bottomEdgePage: 39, maxVisiblePage: 38, totalPages: 38, transitionVisible: true, inForeground: false
        ))
    }

    // MARK: page changes (every reader)

    /// The iPad, 15-nov 14:18: 3 pages read up to 18, the app goes to the background, and 2 s later the
    /// webtoon reports the end transition («página 39...39 de 38») → it was marked read.
    @Test func whatTheIPadDidAt1418DoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [16, 17, 18], inForeground: false))
    }

    @Test func aJumpToTheEndWithoutSeeingTheLastPageDoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [18], inForeground: true))
    }

    @Test func readingToTheEndCompletes() {
        #expect(ReaderCompletion.pageReportCompletes(pages: 38...38, totalPages: 38, seenPages: [36, 37], inForeground: true))
        #expect(ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [36, 37, 38], inForeground: true))
    }

    /// The paged reader keeps what it did: its last spread or a one page chapter completes.
    @Test func thePagedReaderStillCompletesOnItsLastSpread() {
        #expect(ReaderCompletion.pageReportCompletes(pages: 37...38, totalPages: 38, seenPages: [35, 36], inForeground: true))
        #expect(ReaderCompletion.pageReportCompletes(pages: 1...1, totalPages: 1, seenPages: [], inForeground: true))
    }

    @Test func anUnknownTotalDoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 1...1, totalPages: nil, seenPages: [1], inForeground: true))
        #expect(!ReaderCompletion.pageReportCompletes(pages: 1...1, totalPages: 0, seenPages: [1], inForeground: true))
    }
}
