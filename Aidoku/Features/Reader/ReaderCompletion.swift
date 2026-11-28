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
    private var handlers: [@MainActor @Sendable (Bool) -> Void] = []

    init(center: NotificationCenter = .default, active: Bool) {
        self.center = center
        self.isActive = active
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.set(false)
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.set(true)
        })
    }

    /// `handler` hears, on the main thread, the app going out of front and coming back (SUWA-17 H).
    func onChange(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) {
        handlers.append(handler)
    }

    private func set(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        let handlers = handlers
        if Thread.isMainThread {
            MainActor.assumeIsolated { handlers.forEach { $0(active) } }
        } else {
            Task { @MainActor in handlers.forEach { $0(active) } }
        }
    }

    deinit {
        observers.forEach(center.removeObserver)
    }
}

// MARK: - Webtoon descent (SUWA-39 B1)

extension ReaderCompletion {
    /// SUWA-39 B1, webtoon only: whether the user went DOWN a chapter, page after page, to its last page in this
    /// session. A chapter is completed only if they did (by the transition fully on screen, by the page report that
    /// goes into the transition, or by going on to the next chapter from its last page). The reader tells it the pages
    /// of each chapter in turn; `start` is the page it opens at or the one the slider drops the user at.
    struct WebtoonDescent: Equatable {
        /// Where a descent broke: the page before and the one it jumped to (from 0: nothing opened the chapter).
        struct Jump: Equatable {
            let from: Int
            let to: Int
        }

        /// How many pages down a report may be from the highest one reached and still be going down (the transition
        /// and quick swipes). A jump further than that, not from the slider, breaks the descent.
        static let margin = 2

        /// The highest page of the descent so far; nil: nothing started it yet.
        private(set) var reached: Int?
        /// The jump that broke the descent, if one did: from then on the chapter does not complete by itself.
        private(set) var jump: Jump?
        /// The last page reported (where a jump starts from).
        private var last = 0

        /// Nothing started it: the chapter was entered going down from the previous one (its first report counts) or
        /// from below.
        init() {}

        /// A descent that starts at `page`: the page the chapter opens at, or the one the slider drops the user at.
        init(startingAt page: Int) {
            let start = max(1, page)
            reached = start
            last = start
        }

        /// A new page report of the chapter (the transition after the last page is `total + 1`, the one before the
        /// first page is 0).
        mutating func report(page raw: Int) {
            let page = max(1, raw)
            defer { last = page }
            guard jump == nil else { return }
            guard let reached else {
                // nothing opened it: going down from the previous chapter it shows its first page or the next one
                if page <= Self.margin {
                    reached = page
                } else {
                    jump = Jump(from: 0, to: page)
                }
                return
            }
            if page <= reached + Self.margin {
                self.reached = max(reached, page)
            } else {
                jump = Jump(from: last, to: page)
            }
        }

        /// The screen the descent starts on (the one the chapter opened at, or the slider dropped the user at) shows
        /// the pages down to `page`: what is seen counts as reached, so the user's first moves, which tell the page in
        /// the middle of the screen and not the one at its top, are not a jump (SUWA-39 R2-I1). Not once it broke, and
        /// not for a chapter nothing started a descent in.
        mutating func screenShows(upTo page: Int) {
             // pendiente[I1#1]
        }

        /// Whether the chapter, of `totalPages` pages, may be completed: the user went down it to its last page (or the
        /// one before it: the transition fully on screen while the middle of the screen is still on it).
        func allowsCompletion(totalPages: Int) -> Bool {
            guard totalPages > 0, jump == nil, let reached else { return false }
            return reached >= totalPages - 1
        }
    }
}
