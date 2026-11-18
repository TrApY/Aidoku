//
//  ReadingAnchorGeometryTests.swift
//  AidokuTests
//
//  SUWA-20 (ReadingAnchor paso 1): the geometry of the anchor, without views.
//

import CoreGraphics
import Testing

@testable import Aidoku

@Suite struct ReadingAnchorGeometryTests {
    /// Three items of 600, 1200 and 300 points, one under the other.
    private let frames: [(item: Int, frame: CGRect)] = [
        (0, CGRect(x: 0, y: 0, width: 400, height: 600)),
        (1, CGRect(x: 0, y: 600, width: 400, height: 1200)),
        (2, CGRect(x: 0, y: 1800, width: 400, height: 300))
    ]

    @Test func offsetPutsTheFractionOfTheItemOnTheLine() {
        let y = ReadingAnchorGeometry.offset(
            frame: CGRect(x: 0, y: 1000, width: 400, height: 600),
            fraction: 0.25, screenFraction: 0.5, viewportHeight: 800, contentHeight: 5000
        )
        #expect(y == 750) // 1000 + 0.25·600 − 0.5·800
        let top = ReadingAnchorGeometry.offset(
            frame: CGRect(x: 0, y: 1000, width: 400, height: 600),
            fraction: 0, screenFraction: 0, viewportHeight: 800, contentHeight: 5000
        )
        #expect(top == 1000) // the top of the item at the top of the screen (the opening anchor)
    }

    /// Near the start or the end the offset stays inside the content (D10).
    @Test func offsetIsClampedToTheContent() {
        let start = ReadingAnchorGeometry.offset(
            frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            fraction: 0.1, screenFraction: 0.5, viewportHeight: 800, contentHeight: 5000
        )
        #expect(start == 0)
        let end = ReadingAnchorGeometry.offset(
            frame: CGRect(x: 0, y: 4800, width: 400, height: 200),
            fraction: 0.9, screenFraction: 0.5, viewportHeight: 800, contentHeight: 5000
        )
        #expect(end == 4200)
        let short = ReadingAnchorGeometry.offset(
            frame: CGRect(x: 0, y: 100, width: 400, height: 200),
            fraction: 0.5, screenFraction: 0.5, viewportHeight: 800, contentHeight: 500
        )
        #expect(short == 0, "content shorter than the screen")
    }

    /// I5: the item on the line and back gives the same offset.
    @Test func anchorAtTheLineAndBackGivesTheSameOffset() throws {
        // the content is 2100 high and the screen 800: offsets from 0 to 1300
        for offset in [CGFloat(0), 123, 250, 1234, 1299] {
            let line = offset + 0.5 * 800
            let found = try #require(ReadingAnchorGeometry.locate(lineY: line, frames: frames), "nothing at \(line)")
            let frame = try #require(frames.first { $0.item == found.item }?.frame)
            let back = ReadingAnchorGeometry.offset(
                frame: frame, fraction: found.fraction, screenFraction: 0.5, viewportHeight: 800, contentHeight: 2100
            )
            #expect(abs(back - offset) < 0.001, "\(offset) → item \(found.item) at \(found.fraction) → \(back)")
        }
        let middle = try #require(ReadingAnchorGeometry.locate(lineY: 900, frames: frames))
        #expect(middle.item == 1)
        #expect(abs(middle.fraction - 0.25) < 0.0001)
    }

    /// I6: past the content, or on an item without height, there is nothing. Born green with the stub (nil):
    /// it protects what the reader does today with nothing in the middle of the screen.
    @Test func noItemOnTheLineGivesNoAnchor() {
        #expect(ReadingAnchorGeometry.locate(lineY: 2500, frames: frames) == nil)
        #expect(ReadingAnchorGeometry.locate(lineY: -10, frames: frames) == nil)
        let flat: [(item: Int, frame: CGRect)] = [(0, CGRect(x: 0, y: 0, width: 400, height: 0))]
        #expect(ReadingAnchorGeometry.locate(lineY: 0, frames: flat) == nil)
    }

    /// D6: taken at the middle of a provisional item of 600, the item turns out 1200: the same 300 points from its
    /// top, now a quarter of it.
    @Test func aProvisionalItemKeepsTheDistanceToItsTopWhenMeasured() {
        let anchor = ReadingAnchor(chapterKey: "c1", item: 4, fraction: 0.5, screenFraction: 0.5, measured: false)
        let measured = ReadingAnchorGeometry.measured(anchor, provisionalHeight: 600, realHeight: 1200)
        #expect(measured == ReadingAnchor(chapterKey: "c1", item: 4, fraction: 0.25, screenFraction: 0.5, measured: true))
        // an anchor already measured stays as it is
        let real = ReadingAnchor(chapterKey: "c1", item: 4, fraction: 0.5, screenFraction: 0.5, measured: true)
        #expect(ReadingAnchorGeometry.measured(real, provisionalHeight: 600, realHeight: 1200) == real)
    }

    /// D7: zoomed in (frames and line scaled), the item and the fraction are the same.
    @Test func zoomedFramesGiveTheSameFraction() throws {
        let scale: CGFloat = 2.5
        let zoomed: [(item: Int, frame: CGRect)] = frames.map {
            (item: $0.item, frame: $0.frame.applying(CGAffineTransform(scaleX: scale, y: scale)))
        }
        let found = try #require(ReadingAnchorGeometry.locate(lineY: 900 * scale, frames: zoomed))
        #expect(found.item == 1)
        #expect(abs(found.fraction - 0.25) < 0.0001)
    }
}
