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
        guard inForeground, totalPages > 0 else { return false }
        if transitionVisible {
            return true
        }
        guard let maxVisiblePage else { return false }
        return maxVisiblePage >= totalPages
    }

    /// A page change completes the chapter at the last page (or past it, the transition) only if the last
    /// page was seen: in this change or before in this reading session. The paged reader reports it.
    /// `previousPage`: the page before this change (with the app in front).
    static func pageReportCompletes(
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
        // past the last page in one go (37 → 39), as before and as upstream: the transition only comes after
        // it. A jump from further back (18 → 39, the iPad's) doesn't count. SUWA-12 I2
        return pages.lowerBound > totalPages && (previousPage ?? 0) >= totalPages - 2
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
