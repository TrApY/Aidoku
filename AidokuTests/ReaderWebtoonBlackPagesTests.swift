//
//  ReaderWebtoonBlackPagesTests.swift
//  AidokuTests
//
//  SUWA-29 (JoTa, 22-nov): «al bajar en webtoon se ven páginas en negro», also with the chapter downloaded. Through
//  the real reader (the helpers of ReaderWebtoonPreloadTests): the scroll view the user moves is always as long as
//  the pages (F2), a page with its image is never seen fading in from black (A), more margin ahead and nearer pages
//  first (B), the data of the pages coming already on the disk (C), and none of that going on for a chapter no
//  longer shown or after leaving the reader (F1).
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Nuke
import Testing
import UIKit

@testable import Aidoku

// MARK: - F2: the scroll view the user moves follows the pages' height
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// From the server, opened and scrolled down while the pages grow as their images come: in every frame the
    /// scroll view the user moves (the zoom view's) is as long as the pages, not some time after a page grew. It
    /// took the new size when the cell's fade ended (0.3 s); with the image shown at once it was left a page
    /// short for seconds (the first try: 968 pt).
    @Test func theScrollViewTheUserMovesIsAlwaysAsLongAsThePages() async throws {
        let opened = try await open(.remote(delay: 0.3), mangaKey: "contenido", preload: 4)
        var behindSince: ContinuousClock.Instant?
        var longest: Duration = .zero
        var example = ""
        let look: (String) -> Void = { when in
            let scrolled = opened.webtoon.scrollView.contentSize.height
            let pages = opened.layout.collectionViewContentSize.height
            guard abs(scrolled - pages) > 1 else {
                behindSince = nil
                return
            }
            let since = behindSince ?? .now
            behindSince = since
            if ContinuousClock.now - since >= longest {
                longest = ContinuousClock.now - since
                example = "\(when): scroll \(Int(scrolled)), pages \(Int(pages))"
            }
        }
        try await watch(opened, seconds: 4, every: look)
        try await scroll(opened, seconds: 6, velocity: 700, every: look)
        try await watch(opened, seconds: 1, every: look)
        #expect(example.isEmpty || longest < .milliseconds(50), "behind for \(longest): \(example)")
        await opened.close()
    }
}

// MARK: - A: no fade from black
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// A downloaded chapter, opened and scrolled down quickly: a page on screen holding its image is shown whole,
    /// never partly see-through on the black reader (it faded in for 0.3 s each time its cell got it, the moment it
    /// came on screen, although it was decoded long before).
    @Test func aPageWithItsImageIsNeverSeenFadingIn() async throws {
        let opened = try await open(.downloaded, mangaKey: "sinfundido", preload: 2)
        var fading: [String] = []
        var seen = 0
        let look: (String) -> Void = { when in
            for row in opened.pageRows {
                guard
                    let node = opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: row, section: 0)) as? ReaderWebtoonPageNode,
                    node.image != nil,
                    node.imageNode.isNodeLoaded,
                    let frame = opened.frame(row),
                    frame.maxY > opened.top + 0.5,
                    frame.minY < opened.bottom - 0.5
                else { continue }
                seen += 1
                let layer = node.imageNode.layer
                let shown = layer.presentation()?.opacity ?? layer.opacity
                if shown < 0.99, fading.count < 6 {
                    fading.append("\(when): fila \(row) opacidad \(String(format: "%.2f", shown))")
                }
            }
        }
        try await watch(opened, seconds: 2, every: look)
        try await scroll(opened, seconds: 4, velocity: 3000, every: look)
        try await watch(opened, seconds: 1, every: look)
        try #require(seen > 100, "only \(seen) looks at a page with its image on screen")
        #expect(fading.isEmpty, "\(fading)")
        await opened.close()
    }
}

// MARK: - B: more margin ahead, the page above kept, nearer pages first
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    private func node(_ opened: Opened, _ row: Int) -> ReaderWebtoonPageNode? {
        opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: row, section: 0)) as? ReaderWebtoonPageNode
    }

    /// A downloaded chapter, still after opening: the pages that start within the 3.5 screens below the screen
    /// already hold their image, ready to show, whatever «pages to preload» says (before, only «pages to
    /// preload» + 2 from the first one on screen did: 2 with nothing to preload).
    @Test func atRestThePagesOfTheNextScreensHaveTheirImageReady() async throws {
        let opened = try await open(.downloaded, mangaKey: "margen", preload: 0)
        try await watch(opened, seconds: 3) { _ in }
        let screen = opened.webtoon.collectionNode.bounds.height
        let rows = opened.pageRows.filter { (opened.frame($0)?.minY ?? .infinity) < opened.bottom + 3.5 * screen }
        try #require(rows.count >= 4, "only rows \(rows) within 3.5 screens")
        let missing = rows.filter { node(opened, $0)?.image == nil }
        #expect(missing.isEmpty, "rows \(missing) of \(rows) without their image")
        await opened.close()
    }

    /// A downloaded chapter, scrolled down and still: the page right above the screen keeps its image, so going
    /// back up a little shows it at once (before, it let go of it as soon as it left the screen).
    @Test func thePageRightAboveTheScreenKeepsItsImage() async throws {
        let opened = try await open(.downloaded, mangaKey: "encima", preload: 2)
        try await watch(opened, seconds: 2) { _ in }
        try await scroll(opened, seconds: 1.5, velocity: 1500) { _ in }
        try await watch(opened, seconds: 1) { _ in }
        let above = try #require(opened.pageRows.last { (opened.frame($0)?.maxY ?? .infinity) <= opened.top + 0.5 }, "nothing above the screen")
        let page = try #require(node(opened, above))
        #expect(page.image != nil, "row \(above), right above the screen, without its image")
        await opened.close()
    }

    /// From the server, opened and scrolled down: every load going on has the priority of where its page is: on
    /// screen before anything, then the ones about to show (Texture's display range), then the ones loading ahead
    /// (before, the ones on screen high and all the others normal).
    @Test func theLoadsOnScreenGoFirstThenTheOnesAboutToShowThenTheOnesAhead() async throws {
        let opened = try await open(.remote(delay: 0.3), mangaKey: "prioridad", preload: 4)
        var wrong: [String] = []
        var seen: Set<String> = []
        let look: (String) -> Void = { when in
            for row in opened.pageRows {
                guard let page = self.node(opened, row), let priority = page.loadPriority else { continue }
                let expected: ImageRequest.Priority = page.isVisible ? .veryHigh : (page.isInDisplayState ? .high : .normal)
                seen.insert("\(expected)")
                if priority != expected, wrong.count < 6 {
                    wrong.append("\(when): fila \(row) \(priority) en vez de \(expected)")
                }
            }
        }
        try await watch(opened, seconds: 2, every: look)
        try await scroll(opened, seconds: 3, velocity: 1000, every: look)
        try #require(seen.count >= 2, "loads seen only as \(seen.sorted())")
        #expect(wrong.isEmpty, "\(wrong)")
        await opened.close()
    }

    /// After a memory warning, for the pause of the measuring ahead: no more pages hold a decoded image than
    /// before SUWA-29, «pages to preload» + 2 counting the ones on screen (the wider window would decode them all again
    /// at the next scroll, right when the system asked for memory).
    @Test func afterAMemoryWarningNoMorePagesAreDecodedThanBefore() async throws {
        let preload = 2
        let opened = try await open(.downloaded, mangaKey: "memoria", preload: preload)
        try await watch(opened, seconds: 2) { _ in }
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        var over: [String] = []
        var most = 0
        let look: (String) -> Void = { when in
            let limit = max(preload + 2, opened.visibleRows)
            let decoded = opened.decodedImages
            most = max(most, decoded)
            if decoded > limit, over.count < 6 {
                over.append("\(when): \(decoded) > \(limit)")
            }
        }
        try await scroll(opened, seconds: 3, velocity: 1500, every: look)
        try await watch(opened, seconds: 1, every: look)
        try #require(most >= 1)
        #expect(over.isEmpty, "\(over)")
        await opened.close()
    }
}
