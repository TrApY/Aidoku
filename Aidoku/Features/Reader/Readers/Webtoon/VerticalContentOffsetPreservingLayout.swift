//
//  VerticalContentOffsetPreservingLayout.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 3/1/23.
//  Thanks to Mantton (https://github.com/Mantton) for this.
//

import UIKit
import AsyncDisplayKit

class VerticalContentOffsetPreservingLayout: UICollectionViewFlowLayout {

    var onOffsetPreserved: ((CGPoint) -> Void)?
    /// The content size changed in a pass with the same zoom: the scroll view the user moves takes it in the same
    /// pass (SUWA-29). Before, it took it when the transition of the cell that grew ended (0.3 s later, the fade), and
    /// with nothing ending after the layout had it (a page shown at once) it was left a page short for seconds.
    var onContentSizeChanged: ((CGSize) -> Void)?
    /// Where the screen goes after every pass: the reader's anchor (SUWA-19), as the item, the point of it and the
    /// height of the screen it goes at. Nil: nothing to put back this pass.
    var anchorTarget: (() -> (indexPath: IndexPath, fraction: CGFloat, screenFraction: CGFloat)?)?
    /// The layout is putting the screen on the anchor (both scroll views are set one after the other, and the zoom
    /// view syncs them in between): the scroll events meanwhile are not anybody moving (SUWA-19 revisión, hallazgo 4).
    private(set) var isPlacingTheScreen = false

    var spacing: CGFloat {
        get { minimumLineSpacing }
        set { minimumLineSpacing = newValue }
    }

    private var scale: CGFloat = 1
    /// The zoom of the last layout: a pass that changes it is the zoom moving everything on purpose.
    private var lastScale: CGFloat = 1

    private var contentSize = CGSize.zero
    override var collectionViewContentSize: CGSize {
        contentSize
    }

    private var currentAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // every height is the width times its ratio
        guard let collectionView, newBounds.width != collectionView.bounds.width else {
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        return true
    }

    override init() {
        super.init()
        scrollDirection = .vertical
        minimumInteritemSpacing = 0
        minimumLineSpacing = 0
        sectionInset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        guard let collectionView else { return }

        // After every pass with the same zoom, the screen goes back on the reader's anchor (SUWA-19): whatever
        // changed (a chapter put in or trimmed, cells grown as their images load, several at once, the anchor's own
        // cell, a row reloaded, the width: a rotation, iPadOS laying the app out again at other sizes out of front)
        // does not move what is being read. Before, there were five anchors: the cell in the middle of the screen
        // in the previous layout (SUWA-17), the cells growing above asking for it, the middle page on a width
        // change (SUWA-17 H), the rotation's (upstream #1116) and the reader's own when coming back to the front
        let sameScale = !currentAttributes.isEmpty && lastScale == scale

        // calculate collection view size
        currentAttributes = [:]

        var origin: CGFloat = 0
        let width = collectionView.bounds.size.width

        for section in 0..<collectionView.numberOfSections {
            for itemIndex in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: itemIndex, section: section)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)

                let size = CGSize(width: width, height: getHeight(for: indexPath))
                attributes.frame = CGRect(origin: CGPoint(x: 0, y: origin), size: size)
                currentAttributes[indexPath] = attributes

                origin += attributes.frame.size.height + minimumLineSpacing
            }
        }

        // scale for zoom
        let size = CGSize(width: width, height: origin)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let previousContentSize = contentSize
        contentSize = size.applying(transform)

        if scale != 1 {
            // adjust cells for zoom
            for section in 0..<collectionView.numberOfSections {
                for itemIndex in 0..<collectionView.numberOfItems(inSection: section) {
                    let indexPath = IndexPath(item: itemIndex, section: section)
                    if let origFrame = currentAttributes[indexPath]?.frame {
                        let frame = CGRect(
                            origin: CGPoint(
                                x: origFrame.origin.x / size.width * contentSize.width,
                                y: origFrame.origin.y / origin * contentSize.height
                            ),
                            size: origFrame.size.applying(transform)
                        )
                        // setting frame without transform doesn't scale content,
                        // and setting frame with transform messes up the scale
                        currentAttributes[indexPath]?.transform = transform
                        currentAttributes[indexPath]?.center = CGPoint(
                            x: frame.origin.x + frame.width / 2,
                            y: frame.origin.y + frame.height / 2
                        )
                    }
                }
            }
        }

        lastScale = scale

        // (a pass that changes the zoom: the zoom view sizes its content itself)
        if sameScale, contentSize != previousContentSize {
            onContentSizeChanged?(contentSize)
        }

        // the scroll view is left alone when it is already there (every pass set its offset and content size, also
        // while pinching: C3)
        if sameScale, let offset = anchorOffset(), abs(offset.y - collectionView.contentOffset.y) > 0.5 {
            isPlacingTheScreen = true
            defer { isPlacingTheScreen = false }
            UIView.performWithoutAnimation {
                collectionView.contentOffset = offset
                onOffsetPreserved?(offset)
            }
        }
    }

    /// The content offset that puts the reader's anchor where it goes on the screen, with this layout.
    func anchorOffset() -> CGPoint? {
        guard
            let collectionView,
            let target = anchorTarget?(),
            let frame = currentAttributes[target.indexPath]?.frame,
            frame.height > 0
        else { return nil }
        let y = ReadingAnchorGeometry.offset(
            frame: frame,
            fraction: target.fraction,
            screenFraction: target.screenFraction,
            viewportHeight: collectionView.bounds.size.height,
            contentHeight: contentSize.height
        )
        return CGPoint(x: collectionView.contentOffset.x, y: y)
    }

    func getHeight(for indexPath: IndexPath) -> CGFloat {
        guard
            let collectionView = collectionView as? ASCollectionView,
            let collectionNode = collectionView.collectionNode,
            let node = collectionNode.nodeForItem(at: indexPath) as? HeightQueryable
        else {
            return 0
        }
        return node.getHeight(for: collectionView.bounds.size)
    }

    func getHeightFor(section: Int, range: Range<Int>? = nil) -> CGFloat {
        var height: CGFloat = 0
        let range = range ?? 0..<(collectionView?.numberOfItems(inSection: section) ?? 0)
        for idx in range {
            let indexPath = IndexPath(item: idx, section: section)
            let attributes = currentAttributes[indexPath]
            height += attributes?.frame.height ?? 0
        }
        return height * scale
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        currentAttributes[indexPath]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var attributes: [UICollectionViewLayoutAttributes] = []
        for item in currentAttributes where rect.intersects(item.value.frame) {
            attributes.append(item.value)
        }
        return attributes
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        // after an update or a size change, UIKit asks where to go: the anchor (SUWA-19)
        anchorOffset().map { CGPoint(x: proposedContentOffset.x, y: $0.y) } ?? proposedContentOffset
    }
}

// MARK: - Zoom Support
extension VerticalContentOffsetPreservingLayout: @MainActor ZoomableLayoutProtocol {
    func getScale() -> CGFloat {
        scale
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
    }
}
