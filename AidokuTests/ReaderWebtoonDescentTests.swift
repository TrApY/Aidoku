//
//  ReaderWebtoonDescentTests.swift
//  AidokuTests
//
//  SUWA-39 B1: a webtoon chapter is completed only when the user went DOWN it, page after page, to its last
//  page (the iPad, 28-nov 11:51: a jump to the chapter after the next one completed a chapter that was not read).
//  The pure rule, without a reader.
//

import Foundation
import Testing

@testable import Aidoku

struct ReaderWebtoonDescentTests {
    private let total = 32

    /// A descent that starts at `opening` and is told every page of `reports` in turn.
    private func descent(opening: Int, _ reports: [Int]) -> ReaderCompletion.WebtoonDescent {
        var descent = ReaderCompletion.WebtoonDescent(startingAt: opening)
        for page in reports {
            descent.report(page: page)
        }
        return descent
    }

    /// The pages `from...to`, one after the other, the transition after the last one being total + 1.
    private func down(_ from: Int, _ to: Int) -> [Int] {
        Array(from...to)
    }

    @Test func goingDownPageByPageFromTheOpeningPageToTheTransitionIsADescent() {
        let result = descent(opening: 12, down(13, total + 1))
        #expect(result.jump == nil)
        #expect(result.allowsCompletion(totalPages: total))
    }

    @Test func goingDownFromTheFirstPageIsADescent() {
        let result = descent(opening: 1, down(2, total + 1))
        #expect(result.allowsCompletion(totalPages: total))
    }

    /// 12 → 30 without the slider: a jump, and the pages after it do not make up for it.
    @Test func aJumpOfMoreThanTwoPagesDownBreaksTheDescentForGood() {
        let result = descent(opening: 12, down(30, total + 1))
        #expect(result.jump == ReaderCompletion.WebtoonDescent.Jump(from: 12, to: 30))
        #expect(!result.allowsCompletion(totalPages: total))
    }

    /// The margin is two pages: 12 → 14 is still going down, 14 → 17 is not.
    @Test func twoPagesDownIsStillGoingDownAndThreeIsAJump() {
        var result = descent(opening: 12, [14])
        #expect(result.jump == nil)
        result.report(page: 17)
        #expect(result.jump == ReaderCompletion.WebtoonDescent.Jump(from: 14, to: 17))
    }

    /// The margin counts from the highest page reached, not from the last one: going up and coming back down is the
    /// same descent.
    @Test func goingUpDoesNotBreakItAndTheMarginIsFromTheHighestPage() {
        let result = descent(opening: 12, [13, 14, 13, 12, 11, 10, 11, 12, 14, 16])
        #expect(result.jump == nil)
        #expect(result.reached == 16)
    }

    @Test func aBrokenDescentStaysBrokenWhenTheUserGoesBackToWhereItWas() {
        var result = descent(opening: 12, [30])
        for page in down(12, total + 1) {
            result.report(page: page)
        }
        #expect(!result.allowsCompletion(totalPages: total))
        #expect(result.jump == ReaderCompletion.WebtoonDescent.Jump(from: 12, to: 30))
    }

    /// The slider is deliberate: a new descent starts at the page it drops the user at, even after a break.
    @Test func aNewDescentFromTheSliderCompletesGoingDown() {
        var result = descent(opening: 12, [30])
        #expect(!result.allowsCompletion(totalPages: total))
        result = ReaderCompletion.WebtoonDescent(startingAt: 30)
        for page in down(31, total + 1) {
            result.report(page: page)
        }
        #expect(result.jump == nil)
        #expect(result.allowsCompletion(totalPages: total))
    }

    /// A chapter entered going down from the previous one: nothing opened it, its first page does (page 1 or 2; the
    /// transition before the first page is page 0).
    @Test func enteringFromThePreviousChapterStartsAtItsFirstPages() {
        for entry in [0, 1, 2] {
            var result = ReaderCompletion.WebtoonDescent()
            result.report(page: entry)
            for page in down(max(entry, 1) + 1, total + 1) {
                result.report(page: page)
            }
            #expect(result.jump == nil, "entering at \(entry)")
            #expect(result.allowsCompletion(totalPages: total), "entering at \(entry)")
        }
    }

    /// Nobody opened it and the first report is page 5: it is not a descent (it came by a jump, or from below).
    @Test func aChapterFirstSeenFurtherThanItsSecondPageIsNotADescent() {
        var result = ReaderCompletion.WebtoonDescent()
        result.report(page: 5)
        for page in down(6, total + 1) {
            result.report(page: page)
        }
        #expect(result.jump == ReaderCompletion.WebtoonDescent.Jump(from: 0, to: 5))
        #expect(!result.allowsCompletion(totalPages: total))
    }

    /// Opened at page 12 and nothing more: the end was not reached.
    @Test func aDescentThatDidNotReachTheEndDoesNotComplete() {
        #expect(!descent(opening: 12, down(13, 20)).allowsCompletion(totalPages: total))
        #expect(!ReaderCompletion.WebtoonDescent().allowsCompletion(totalPages: total))
    }

    /// The chapter opens at its last page (SUWA-17: it opens there again) and the user goes on to the transition.
    @Test func openingAtTheLastPageAndGoingIntoTheTransitionCompletes() {
        let result = descent(opening: total, [total + 1])
        #expect(result.jump == nil)
        #expect(result.allowsCompletion(totalPages: total))
    }

    /// The transition fully on screen (the reader's other way to complete) with the middle of the screen still on the
    /// page before the last one (tiny last pages): going down to it is enough.
    @Test func theTransitionFullyOnScreenCompletesFromThePageBeforeTheLast() {
        #expect(descent(opening: 1, down(2, total - 1)).allowsCompletion(totalPages: total))
        #expect(!descent(opening: 1, down(2, total - 2)).allowsCompletion(totalPages: total))
    }

    @Test func aChapterWithoutPagesNeverCompletes() {
        #expect(!descent(opening: 1, []).allowsCompletion(totalPages: 0))
    }

    // MARK: - SUWA-39 R2-I1: what the screen shows counts as reached

    /// Opened at page 1 on a tall screen (seven short pages on it): the first move tells the page in the middle of the
    /// screen, the fifth. Without the screen's pages that is a jump from 1 to 5; with them, going down.
    @Test func theFirstMoveToThePageInTheMiddleOfTheOpeningScreenIsNotAJump() {
        var broken = ReaderCompletion.WebtoonDescent(startingAt: 1)
        broken.report(page: 5)
        #expect(broken.jump == ReaderCompletion.WebtoonDescent.Jump(from: 1, to: 5))

        var result = ReaderCompletion.WebtoonDescent(startingAt: 1)
        result.screenShows(upTo: 7)
        #expect(result.reached == 7)
        for page in [5, 6, 7, 8, 9] + down(10, total + 1) {
            result.report(page: page)
        }
        #expect(result.jump == nil)
        #expect(result.allowsCompletion(totalPages: total))
    }

    /// What the screen showed is the margin's start: two pages further is still going down, three is a jump.
    @Test func theMarginCountsFromTheLastPageTheScreenShowed() {
        var result = ReaderCompletion.WebtoonDescent(startingAt: 1)
        result.screenShows(upTo: 7)
        result.report(page: 9)
        #expect(result.jump == nil)
        result.report(page: 13)
        #expect(result.jump == ReaderCompletion.WebtoonDescent.Jump(from: 9, to: 13))
    }

    /// The slider drops the user at 30 and the screen there shows down to 32: a new descent whose first moves, to the
    /// page in the middle of the screen, are not jumps.
    @Test func theScreenWhereTheSliderDroppedTheUserCountsToo() {
        var result = ReaderCompletion.WebtoonDescent(startingAt: 12)
        result.report(page: 25)
        #expect(result.jump != nil)
        result = ReaderCompletion.WebtoonDescent(startingAt: 25)
        result.screenShows(upTo: 28)
        for page in down(27, total + 1) {
            result.report(page: page)
        }
        #expect(result.jump == nil)
        #expect(result.allowsCompletion(totalPages: total))
    }

    /// A screen that comes later changes nothing for a descent that broke, nor for one nothing started.
    @Test func theScreenDoesNotMendABrokenDescentNorStartOne() {
        var result = descent(opening: 12, [30])
        let broken = result
        result.screenShows(upTo: 32)
        #expect(result == broken)
        #expect(!result.allowsCompletion(totalPages: total))

        var unstarted = ReaderCompletion.WebtoonDescent()
        unstarted.screenShows(upTo: 7)
        #expect(unstarted.reached == nil)
        unstarted.report(page: 5)
        #expect(unstarted.jump == ReaderCompletion.WebtoonDescent.Jump(from: 0, to: 5))
    }

}
