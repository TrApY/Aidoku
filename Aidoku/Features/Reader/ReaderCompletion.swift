//
//  ReaderCompletion.swift
//  Aidoku
//
//  SUWA-12 H: when a reader marks the chapter completed. Only with the end of the chapter really on
//  screen, and never with the app in the background (iPadOS lays the app out again for the app switcher
//  snapshots, and the webtoon reported the end transition then: the iPad, 15-nov 14:18:19, page 18 of 38).
//

import Foundation
import UIKit

enum ReaderCompletion {
    // SUWA-17 (JoTa, 16-nov): a chapter is completed when the user, with the app in front, goes from its last
    // page to what comes after it: the transition, or the first page of the next chapter (or the «no more
    // chapters» transition if it is the last). Seeing the last page alone does not complete it (it is saved as
    // the current page, so the chapter opens there again). It replaces SUWA-12 H/I «complete on seeing the last
    // page»; the rest stays: nothing with the app out of front, nor a big jump without seeing the last page.

    /// Webtoon / continuous, when the scroll stops, at the end of what is loaded: the transition after the last
    /// page fully on screen and no chapter after it (the middle of the screen, the page reported, cannot get
    /// into a short transition at the very end). With the next chapter loaded below, it is the page reported
    /// that passes into the transition (`pageReportCompletes`).
    static func webtoonReachedEnd(
        totalPages: Int,
        transitionFullyVisible: Bool,
        nextChapterLoaded: Bool,
        inForeground: Bool
    ) -> Bool {
        guard inForeground, totalPages > 0, !nextChapterLoaded else { return false }
        return transitionFullyVisible
    }

    /// A page change completes the chapter when it goes past the last page (the transition is reported as the
    /// page after the last one) and the last page was seen before in this reading session.
    /// `previousPage`: the page before this change (with the app in front).
    static func pageReportCompletes(
        pages: ClosedRange<Int>,
        totalPages: Int?,
        seenPages: Set<Int>,
        previousPage: Int? = nil,
        inForeground: Bool
    ) -> Bool {
        guard inForeground, let totalPages, totalPages > 0, pages.lowerBound > totalPages else { return false }
        if seenPages.contains(totalPages) {
            return true
        }
        // past the last page in one go (37 → 39), as before and as upstream: the transition only comes after
        // it. A jump from further back (18 → 39, the iPad's) doesn't count. SUWA-12 I2
        return (previousPage ?? 0) >= totalPages - 2
    }

    /// The text readers have no transition: they keep the rule of SUWA-12 (the last page reached, seen in this
    /// change or before), and the scrolling one completes at the end of the text on its own.
    static func textPageReportCompletes(
        pages: ClosedRange<Int>,
        totalPages: Int?,
        seenPages: Set<Int>,
        previousPage: Int? = nil,
        inForeground: Bool
    ) -> Bool {
        guard inForeground, let totalPages, totalPages > 0, pages.upperBound >= totalPages else { return false }
        if pages.contains(totalPages) || seenPages.contains(totalPages) {
            return true
        }
        return pages.lowerBound > totalPages && (previousPage ?? 0) >= totalPages - 2
    }

    /// Going to the next chapter (the paged reader turning past the transition, the webtoon past it in one go, the
    /// next chapter button) completes the one left if its last page was seen.
    static func chapterChangeCompletes(forward: Bool, lastPageSeen: Bool, inForeground: Bool) -> Bool {
        inForeground && forward && lastPageSeen
    }
}

/// Whether the app is in front for the reader: not from «will resign active» or «did enter background»
/// until «did become active» (iPadOS lays the app out again for the app switcher then). SUWA-12 I1.
final class ReaderAppActivity: @unchecked Sendable {
    private(set) var isActive: Bool
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default, active: Bool) {
        self.center = center
        self.isActive = active
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.isActive = false
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.isActive = true
        })
    }

    deinit {
        observers.forEach(center.removeObserver)
    }
}
