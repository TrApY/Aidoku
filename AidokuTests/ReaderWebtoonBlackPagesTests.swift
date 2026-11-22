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

// MARK: - C: the data of the pages coming, on the disk before they load
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// The server address of page `index` of chapter 1.
    private func serverURL(_ opened: Opened, _ index: Int) throws -> URL {
        try #require(URL(string: SlowImageLoader.serverURL(opened.directory.appendingPathComponent("c1-\(index).jpg"))))
    }

    /// From the server, still on the first page: the data of the 10 pages after the screen is asked for and
    /// stays in the disk cache, also for the pages too far down to be loaded or decoded yet (before, only the
    /// «pages to preload» ones measured ahead and the ones in Texture's preload range were asked for).
    @Test func fromTheServerTheDataOfTheTenNextPagesComesAheadWithoutDecodingThem() async throws {
        let opened = try await open(.remote(delay: 0.3), mangaKey: "adelantados", preload: 2)
        let loader = try #require(opened.loader)
        let dataCache = try #require(opened.dataCache)
        try await watch(opened, seconds: 0.5) { _ in }
        let last = try #require(opened.lastVisibleRow)
        // row r is page r - 1
        let wanted = Array(last...min(last + 9, Self.pageCount - 1))
        var asked: [Int] = []
        for _ in 0..<80 {
            asked = wanted.filter { index in loader.requested.contains { $0.hasSuffix("/c1-\(index).jpg") } }
            if asked.count == wanted.count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(asked == wanted, "pages \(Set(wanted).subtracting(asked).sorted()) after the screen never asked for")
        // the furthest ones, never within the 4 screens below the screen (from page 9 on, even at the provisional
        // height): on the disk, not decoded
        try await watch(opened, seconds: 1) { _ in }
        let screen = opened.webtoon.collectionNode.bounds.height
        let far = wanted.filter { $0 >= 8 }
        try #require(!far.isEmpty && far.allSatisfy { (opened.frame($0 + 1)?.minY ?? 0) > opened.bottom + 4 * screen + 1 }, "pages \(far) not further than 4 screens below")
        let notOnDisk = try far.filter { index in
            let key = ImagePipeline.shared.cache.makeDataCacheKey(for: ImageRequest(url: try serverURL(opened, index)))
            return !dataCache.containsData(for: key)
        }
        #expect(notOnDisk.isEmpty, "pages \(notOnDisk) not in the disk cache")
        let decoded = far.filter { (opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: $0 + 1, section: 0)) as? ReaderWebtoonPageNode)?.image != nil }
        #expect(decoded.isEmpty, "pages \(decoded), further than 4 screens below, decoded")
        await opened.close()
    }

    /// From the server: leaving the reader while the data of the pages after the screen is coming stops it (the
    /// server, from page 10 on, sends nothing until it is let go).
    @Test func leavingTheReaderStopsTheDataComingAhead() async throws {
        let opened = try await open(.remote(delay: 0.05), mangaKey: "salir", preload: 2, heldFrom: 9)
        let loader = try #require(opened.loader)
        let far: (String) -> Bool = { path in (9..<Self.pageCount).contains { path.hasSuffix("/c1-\($0).jpg") } }
        for _ in 0..<40 where !loader.pending.contains(where: far) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(loader.pending.contains(where: far), "nothing from page 10 on asked for")
        opened.reader.beginAppearanceTransition(false, animated: false)
        opened.reader.endAppearanceTransition()
        try await watch(opened, seconds: 0.5) { _ in }
        let still = loader.pending.filter(far)
        #expect(still.isEmpty, "\(still.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()) still asked for after leaving")
        loader.release()
        await opened.close()
    }
}

// MARK: - F1: nothing downloaded ahead for a chapter no longer shown or after leaving the reader
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// In one turn of the main thread, the user goes two screens down (the data of the pages after them is asked
    /// for: their requests are made ready first, the source's are awaited) and something else happens; a second
    /// later, none of the pages of chapter 1 that only the downloading ahead asks for (from page 12 on: the nearer
    /// ones may be loading to show) is still asked for.
    private func movedDownAndThen(_ key: String, _ then: (Opened) -> Void) async throws {
        let opened = try await open(.remote(delay: 1.0), mangaKey: key, preload: 2)
        let loader = try #require(opened.loader)
        try await watch(opened, seconds: 1) { _ in }
        let scrollView = opened.webtoon.scrollView
        opened.webtoon.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset = CGPoint(x: 0, y: scrollView.contentOffset.y + 2 * scrollView.bounds.height)
        opened.webtoon.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        then(opened)
        try await watch(opened, seconds: 1) { _ in }
        let old = loader.pending.filter { path in (11..<Self.pageCount).contains { path.hasSuffix("/c1-\($0).jpg") } }
        #expect(old.isEmpty, "\(old.count) pages of chapter 1 still asked for: \(old.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted())")
        await opened.close()
    }

    /// … another chapter is opened, one whose pages do not come (the source failed: no pages take the place of the
    /// ones of chapter 1 after the screen).
    @Test func aChapterOpenedWhileTheNextPagesAreMadeReadyStartsNoneOfThem() async throws {
        try await movedDownAndThen("carrera-capitulo") { opened in
            opened.webtoon.setChapter(AidokuRunner.Chapter(key: "c3", chapterNumber: 3), startPage: 1)
        }
    }

    /// … the user leaves the reader.
    @Test func leavingTheReaderWhileTheNextPagesAreMadeReadyStartsNoneOfThem() async throws {
        try await movedDownAndThen("carrera-salir") { opened in
            opened.reader.beginAppearanceTransition(false, animated: false)
            opened.reader.endAppearanceTransition()
        }
    }
}

// MARK: - Review: the memory of the pages decoded beyond the ones of before
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// Wide and short pages (2800 × 2000 pixels, 22 MB each decoded, a third of the screen each on an iPhone):
    /// many fit in the 4 screens below the screen. Still and scrolled down, the decoded images of the pages beyond
    /// the ones of before (on screen and «pages to preload» + 2 from the first one on it) stay within 150 MB and one
    /// page more (the one that went over), in two looks in a row.
    @Test func wideShortPagesDecodedAheadStayWithinTheirMemory() async throws {
        let preload = 2
        let opened = try await open(.downloaded, mangaKey: "anchas", preload: preload) { _ in CGSize(width: 2800, height: 2000) }
        let budget = 150 * 1024 * 1024
        let page = 2800 * 2000 * 4
        var over: [String] = []
        var most = 0
        var overBefore = false
        let look: (String) -> Void = { when in
            let firstOnScreen = opened.pageRows.first { (opened.frame($0)?.maxY ?? 0) > opened.top + 0.5 } ?? 1
            var extra = 0
            for row in opened.pageRows {
                guard
                    let node = opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: row, section: 0)) as? ReaderWebtoonPageNode,
                    let image = node.image?.cgImage,
                    let frame = opened.frame(row)
                else { continue }
                let onScreen = (frame.maxY > opened.top + 0.5 && frame.minY < opened.bottom - 0.5) || node.isVisible
                let asBefore = onScreen || (row >= firstOnScreen && row - firstOnScreen < preload + 2)
                if !asBefore {
                    extra += image.bytesPerRow * image.height
                }
            }
            most = max(most, extra)
            let isOver = extra > budget + page
            if isOver, overBefore, over.count < 6 {
                over.append("\(when): \(extra / 1_048_576) MB")
            }
            overBefore = isOver
        }
        try await watch(opened, seconds: 3, every: look)
        try await scroll(opened, seconds: 3, velocity: 1500, every: look)
        try await watch(opened, seconds: 2, every: look)
        #expect(over.isEmpty, "most \(most / 1_048_576) MB beyond the pages of before: \(over)")
        await opened.close()
    }
}

// MARK: - Review: no frame of black between becoming opaque and showing the image
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// The image node of a page, its view loaded, given an image on the main thread: its view has it at once, in
    /// the same pass the page becomes opaque (before, a turn of the main queue later: with no fade to hide it, a
    /// frame of the black reader).
    @Test func anImageGivenOnTheMainThreadIsInItsViewAtOnce() async throws {
        let node = GIFImageNode()
        _ = node.view
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        node.image = image
        #expect(node.imageView?.image === image, "the view has \(String(describing: node.imageView?.image))")
    }
}
