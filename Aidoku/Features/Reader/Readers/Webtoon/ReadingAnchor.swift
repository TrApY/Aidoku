//
//  ReadingAnchor.swift
//  Aidoku
//
//  SUWA-19 (ReadingAnchor): where the user is reading in the webtoon reader, in logical terms (chapter, item,
//  where in it) instead of a scroll offset. Only the user moves it; the layout puts the screen back on it after
//  every change of heights, width or chapters. Spec: ~/aidoku/notas/spec-reading-anchor.md.
//

import CoreGraphics

/// Where the user is reading: this point of this item is at this height of the screen.
struct ReadingAnchor: Equatable, Sendable {
    /// The chapter (its key).
    var chapterKey: String
    /// The item in the chapter's items in the reader (pages and transitions), as `IndexPath.item`.
    var item: Int
    /// The point of the item on the line: 0 its top, 1 its bottom.
    var fraction: CGFloat
    /// Where the line is on the screen: 0 its top, 0.5 its middle (where the user's movements put it).
    var screenFraction: CGFloat
    /// The item had its real height (not the provisional one) when the anchor was taken.
    var measured: Bool
}

/// The geometry of the anchor, without views (SUWA-19 D11).
enum ReadingAnchorGeometry {
    /// The content offset that puts `fraction` of the item with `frame` at `screenFraction` of the viewport, kept
    /// inside the content (the anchor itself does not change when it cannot be reached: D10).
    static func offset(
        frame: CGRect,
        fraction: CGFloat,
        screenFraction: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        let y = frame.minY + fraction * frame.height - screenFraction * viewportHeight
        return min(max(y, 0), max(0, contentHeight - viewportHeight))
    }

    /// The item whose frame holds the line (`lineY`, in content coordinates) and where in it: nil if none does or
    /// it has no height.
    static func locate(lineY: CGFloat, frames: [(item: Int, frame: CGRect)]) -> (item: Int, fraction: CGFloat)? {
        guard let found = frames.first(where: { $0.frame.height > 0 && $0.frame.minY <= lineY && $0.frame.maxY > lineY })
        else { return nil }
        return (found.item, (lineY - found.frame.minY) / found.frame.height)
    }

    /// An anchor taken on an item with its provisional height, once the item has its real one: the same distance
    /// to the item's top (a fraction of a made-up height means nothing: D6).
    static func measured(_ anchor: ReadingAnchor, provisionalHeight: CGFloat, realHeight: CGFloat) -> ReadingAnchor {
        guard !anchor.measured, realHeight > 0 else { return anchor }
        var measured = anchor
        measured.fraction = min(max(anchor.fraction * provisionalHeight / realHeight, 0), 1)
        measured.measured = true
        return measured
    }
}
