//
//  ReaderHoldingDelegate.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/16/22.
//

import Foundation
import AidokuRunner

protocol ReaderHoldingDelegate: AnyObject {
    var barsHidden: Bool { get }

    func hideBars()

    func getNextChapter() -> AidokuRunner.Chapter?
    func getPreviousChapter() -> AidokuRunner.Chapter?
    func setChapter(_ chapter: AidokuRunner.Chapter)

    func setCurrentPage(_ page: Int, position: Double?)
    /// The webtoon reader: the user went up inside the chapter entered from below by scrolling (SUWA-17 F3, G1).
    func movedUpIntoChapter()
    func setCurrentPages(_ pages: ClosedRange<Int>)
    func setPages(_ pages: [Page])
    func displayPage(_ page: Int) // show page on toolbar but don't set it as current page
    func setSliderOffset(_ offset: CGFloat)
    /// false if it didn't count (incognito, the app not in front)
    @discardableResult func setCompleted() -> Bool
}

extension ReaderHoldingDelegate {
    func movedUpIntoChapter() {}
}
