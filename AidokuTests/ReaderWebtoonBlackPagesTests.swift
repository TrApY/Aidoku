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
