//
//  ReaderCompletionTests.swift
//  AidokuTests
//
//  SUWA-12 H1: a reader marks the chapter completed only with the app in the foreground.
//  SUWA-17 (JoTa, 16-nov): and only when the user goes from the last page to what comes after it (the transition
//  or the next chapter); seeing the last page alone no longer completes it.
//

import Foundation
import Testing

@testable import Aidoku

@Suite struct ReaderCompletionTests {
    // MARK: webtoon / continuous, when the scroll stops at the end of what is loaded

    @Test func aGapBetweenPagesMidChapterDoesNotComplete() {
        // nothing under the bottom edge (the 15 pt between pages, or sizes still changing), page 20 of 38
        #expect(!ReaderCompletion.webtoonReachedEnd(
            totalPages: 38, transitionFullyVisible: false, nextChapterLoaded: false, inForeground: true
        ))
    }

    /// SUWA-17: was `theLastPageOnScreenCompletes` (true). The last page on screen is where the chapter opens
    /// again; it is not completed until the user goes past it.
    @Test func theLastPageOnScreenNoLongerCompletes() {
        #expect(!ReaderCompletion.webtoonReachedEnd(
            totalPages: 38, transitionFullyVisible: false, nextChapterLoaded: false, inForeground: true
        ))
    }

    /// The «no more chapters» transition entirely on screen at the very end: the user went past the last page.
    @Test func theFinalTransitionOnScreenCompletes() {
        #expect(ReaderCompletion.webtoonReachedEnd(
            totalPages: 38, transitionFullyVisible: true, nextChapterLoaded: false, inForeground: true
        ))
    }

    /// With the next chapter below, it is the page in the middle of the screen getting into the transition (a
    /// page report) that completes, not the transition showing under the last page.
    @Test func withTheNextChapterBelowTheTransitionOnScreenDoesNotComplete() {
        #expect(!ReaderCompletion.webtoonReachedEnd(
            totalPages: 38, transitionFullyVisible: true, nextChapterLoaded: true, inForeground: true
        ))
    }

    @Test func noPagesKnownDoesNotComplete() {
        #expect(!ReaderCompletion.webtoonReachedEnd(
            totalPages: 0, transitionFullyVisible: false, nextChapterLoaded: false, inForeground: true
        ))
        #expect(!ReaderCompletion.webtoonReachedEnd(
            totalPages: 0, transitionFullyVisible: true, nextChapterLoaded: false, inForeground: true
        ))
    }

    @Test func inTheBackgroundTheWebtoonDoesNotComplete() {
        #expect(!ReaderCompletion.webtoonReachedEnd(
            totalPages: 38, transitionFullyVisible: true, nextChapterLoaded: false, inForeground: false
        ))
    }

    // MARK: page changes (paged and webtoon)

    /// The iPad, 15-nov 14:18: 3 pages read up to 18, the app goes to the background, and 2 s later the
    /// webtoon reports the end transition («página 39...39 de 38») → it was marked read.
    @Test func whatTheIPadDidAt1418DoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [16, 17, 18], inForeground: false))
    }

    @Test func aJumpToTheEndWithoutSeeingTheLastPageDoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [18], inForeground: true))
    }

    /// SUWA-17: the first assertion was true (reaching page 38 completed); now only going past it does.
    @Test func readingToTheEndCompletesWhenGoingPastTheLastPage() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 38...38, totalPages: 38, seenPages: [36, 37], inForeground: true))
        #expect(ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [36, 37, 38], inForeground: true))
    }

    /// SUWA-17: was `thePagedReaderStillCompletesOnItsLastSpread` (both true). The last spread, or the only page
    /// of a one-page chapter, is not completed until the transition after it.
    @Test func thePagedReaderCompletesAfterItsLastSpread() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 37...38, totalPages: 38, seenPages: [35, 36], inForeground: true))
        #expect(ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [35, 36, 37, 38], inForeground: true))
        #expect(!ReaderCompletion.pageReportCompletes(pages: 1...1, totalPages: 1, seenPages: [], inForeground: true))
        #expect(ReaderCompletion.pageReportCompletes(pages: 2...2, totalPages: 1, seenPages: [1], inForeground: true))
    }

    @Test func anUnknownTotalDoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 1...1, totalPages: nil, seenPages: [1], inForeground: true))
        #expect(!ReaderCompletion.pageReportCompletes(pages: 1...1, totalPages: 0, seenPages: [1], inForeground: true))
    }

    /// The text readers have no transition: they keep the old rule (the last page reached).
    @Test func theTextReadersKeepTheirRule() {
        #expect(ReaderCompletion.textPageReportCompletes(pages: 38...38, totalPages: 38, seenPages: [36, 37], inForeground: true))
        #expect(ReaderCompletion.textPageReportCompletes(pages: 1...1, totalPages: 1, seenPages: [], inForeground: true))
        #expect(!ReaderCompletion.textPageReportCompletes(pages: 38...38, totalPages: 38, seenPages: [], inForeground: false))
    }

    // MARK: going to the next chapter

    @Test func goingToTheNextChapterFromTheLastPageCompletes() {
        #expect(ReaderCompletion.chapterChangeCompletes(forward: true, lastPageSeen: true, inForeground: true))
        #expect(!ReaderCompletion.chapterChangeCompletes(forward: true, lastPageSeen: false, inForeground: true))
        #expect(!ReaderCompletion.chapterChangeCompletes(forward: false, lastPageSeen: true, inForeground: true))
        #expect(!ReaderCompletion.chapterChangeCompletes(forward: true, lastPageSeen: true, inForeground: false))
    }
}
