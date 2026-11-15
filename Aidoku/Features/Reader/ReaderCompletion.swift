//
//  ReaderCompletion.swift
//  Aidoku
//
//  SUWA-12 H: when a reader marks the chapter completed. Only with the end of the chapter really on
//  screen, and never with the app in the background (iPadOS lays the app out again for the app switcher
//  snapshots, and the webtoon reported the end transition then: the iPad, 15-nov 14:18:19, page 18 of 38).
//

import Foundation

enum ReaderCompletion {
    /// Webtoon / continuous, when the scroll stops: the last page of the chapter on screen, or the
    /// transition after it. Not a gap under the bottom edge (between pages or while sizes change).
    /// `bottomEdgePage`: the page under the bottom edge (nil: none), only for the old rule.
    static func webtoonReachedEnd(
        bottomEdgePage: Int?,
        maxVisiblePage: Int?,
        totalPages: Int,
        transitionVisible: Bool,
        inForeground: Bool
    ) -> Bool {
        return bottomEdgePage.map { $0 >= totalPages } ?? true // pendiente[H1#1]
    }

    /// A page change completes the chapter at the last page (or past it, the transition) only if the last
    /// page was seen: in this change or before in this reading session. The paged reader reports it.
    static func pageReportCompletes(
        pages: ClosedRange<Int>,
        totalPages: Int?,
        seenPages: Set<Int>,
        inForeground: Bool
    ) -> Bool {
        return totalPages.map { pages.upperBound >= $0 } ?? false // pendiente[H1#2]
    }
}
