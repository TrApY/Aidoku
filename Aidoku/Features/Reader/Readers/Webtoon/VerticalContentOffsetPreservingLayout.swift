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

    private(set) var isChangingCellsAbove: Bool = false
    var onOffsetPreserved: ((CGPoint) -> Void)?

    func preserveOffsetAcrossChangeAbove() {
        isChangingCellsAbove = true
    }

    var spacing: CGFloat {
        get { minimumLineSpacing }
        set { minimumLineSpacing = newValue }
    }

    private var scale: CGFloat = 1
    /// The width and zoom of the last layout: the top visible cell is only kept in place between two layouts of
    /// the same geometry (a rotation or a zoom moves everything on purpose).
    private var lastWidth: CGFloat = 0
    private var lastScale: CGFloat = 1

    private var contentSize = CGSize.zero
    override var collectionViewContentSize: CGSize {
        contentSize
    }

    private var currentAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var itemIdentifiers: [IndexPath: AnyHashable] = [:]
    /// The number of items of each section in the last layout.
    private var itemCounts: [Int] = []

    private struct ViewportAnchor {
        let indexPath: IndexPath
        let position: CGPoint
    }

    private var preservedViewportAnchor: ViewportAnchor?

    /// Width changes of the layout so far (SUWA-17 H).
    private(set) var widthChanges = 0

    /// The cell in the middle of the screen and where in it the middle is (0 its top, 1 its bottom).
    private struct MiddleAnchor {
        let indexPath: IndexPath
        let identifier: AnyHashable?
        let fraction: CGFloat
    }

    /// The middle of the screen right before the width changes (SUWA-17 H).
    private var widthChangeAnchor: MiddleAnchor?
    /// The offset that keeps the middle page after the width changed, until the end of this pass: UIKit then
    /// scales the offset by the content's size on top of it, and the webtoon puts it back (SUWA-17 H).
    private(set) var widthChangeOffset: CGPoint?

    private func middleAnchor(in bounds: CGRect) -> MiddleAnchor? {
        let middleY = bounds.midY
        guard
            let attributes = currentAttributes.values.first(where: { $0.frame.minY <= middleY && $0.frame.maxY > middleY }),
            attributes.frame.height > 0
        else { return nil }
        return MiddleAnchor(
            indexPath: attributes.indexPath,
            identifier: itemIdentifiers[attributes.indexPath],
            fraction: (middleY - attributes.frame.minY) / attributes.frame.height
        )
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView, newBounds.width != collectionView.bounds.width else {
            return super.shouldInvalidateLayout(forBoundsChange: newBounds)
        }
        // the width is about to change: the middle of the screen as it is now (SUWA-17 H)
        if widthChangeAnchor == nil {
            widthChangeAnchor = middleAnchor(in: collectionView.bounds)
        }
        return true
    }

    func preserveVisiblePosition() {
        guard let collectionView else { return }

        let bounds = collectionView.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        guard
            let attributes = layoutAttributesForElements(in: bounds)?
                .filter({ $0.representedElementCategory == .cell && $0.frame.width > 0 && $0.frame.height > 0 })
                .min(by: {
                    let first = max($0.frame.minY - center.y, center.y - $0.frame.maxY, 0)
                    let second = max($1.frame.minY - center.y, center.y - $1.frame.maxY, 0)
                    return first < second
                })
        else {
            preservedViewportAnchor = nil
            return
        }

        preservedViewportAnchor = ViewportAnchor(
            indexPath: attributes.indexPath,
            position: CGPoint(
                x: (center.x - attributes.frame.minX) / attributes.frame.width,
                y: (center.y - attributes.frame.minY) / attributes.frame.height
            )
        )
    }

    func clearPreservedPosition() {
        preservedViewportAnchor = nil
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

        // Anchor the cell in the middle of the screen (the one being read) using the previous layout, and not only
        // when asked: whatever changed above it (a chapter put in, cells grown as their images load, several at
        // once, the top cell itself) must not move what is being read. The old anchor was the top visible cell:
        // when only its bottom showed and it grew, everything under it slid down by its growth (into the previous
        // chapter, SUWA-17); and a growing cell asked after the pass that applied its growth (SUWA-16)
        let sameGeometry = !currentAttributes.isEmpty && lastWidth == collectionView.bounds.size.width && lastScale == scale
        // The width changing with nothing else asked (iPadOS lays the app out again at other sizes: the app
        // switcher, Stage Manager, a window; a rotation has its own anchor from viewWillTransition): every height
        // is the width times its ratio, so the same offset would be another page, or another chapter. The page in
        // the middle of the screen stays there, at the same place inside it, and that is all: not the anchor of
        // the cells above (all of them change, and say so as they lay out again for the new width), nor UIKit
        // scaling the offset by the content's size on top of it (SUWA-17 H)
        let widthChanged = !currentAttributes.isEmpty && lastWidth != collectionView.bounds.size.width
        let proportional = widthChanged && lastScale == scale && preservedViewportAnchor == nil
            ? widthChangeAnchor ?? middleAnchor(in: collectionView.bounds)
            : nil
        widthChangeAnchor = nil
        widthChangeOffset = nil
        if widthChanged {
            widthChanges += 1
        }
        let middleY = collectionView.contentOffset.y + collectionView.bounds.size.height / 2
        let middleCell = currentAttributes.values.first { $0.frame.minY <= middleY && $0.frame.maxY > middleY }
        let anchor = proportional == nil && (isChangingCellsAbove || sameGeometry) ? middleCell ?? currentAttributes.values
            .filter { $0.frame.maxY > collectionView.contentOffset.y }
            .min { $0.frame.minY < $1.frame.minY } : nil
        let anchorPath = anchor?.indexPath
        let anchorIdentifier = anchorPath.flatMap { itemIdentifiers[$0] }
        let oldAnchorY = anchor?.frame.minY
        let oldItemCounts = itemCounts
        isChangingCellsAbove = false

        // calculate collection view size
        currentAttributes = [:]
        itemIdentifiers = [:]

        var origin: CGFloat = 0
        let width = collectionView.bounds.size.width

        for section in 0..<collectionView.numberOfSections {
            for itemIndex in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: itemIndex, section: section)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)

                let size = CGSize(width: width, height: getHeight(for: indexPath))
                attributes.frame = CGRect(origin: CGPoint(x: 0, y: origin), size: size)
                currentAttributes[indexPath] = attributes
                itemIdentifiers[indexPath] = itemIdentifier(for: indexPath)

                origin += attributes.frame.size.height + minimumLineSpacing
            }
        }

        // scale for zoom
        let size = CGSize(width: width, height: origin)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
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

        lastWidth = width
        lastScale = scale
        itemCounts = (0..<collectionView.numberOfSections).map { collectionView.numberOfItems(inSection: $0) }

        if
            let proportional,
            let path = proportional.identifier.flatMap({ identifier in
                itemIdentifiers.first(where: { $0.value == identifier })?.key
            }) ?? (oldItemCounts == itemCounts ? proportional.indexPath : nil),
            let frame = currentAttributes[path]?.frame, frame.height > 0
        {
            let height = collectionView.bounds.size.height
            let maxY = max(0, contentSize.height - height)
            let y = min(max(frame.minY + frame.height * proportional.fraction - height / 2, 0), maxY)
            let offset = CGPoint(x: collectionView.contentOffset.x, y: y)
            widthChangeOffset = offset
            Task { @MainActor [weak self] in
                self?.widthChangeOffset = nil
            }
            if abs(y - collectionView.contentOffset.y) > 0.01 {
                UIView.performWithoutAnimation {
                    collectionView.contentOffset = offset
                    onOffsetPreserved?(offset)
                }
            }
        }

        // Only movement of the anchor counts, not resizing of cells; and the scroll view is left alone when
        // there is nothing to make up for (every pass set its offset and content size, also while pinching)
        // The anchor is found by its node; a reloaded row (refreshInfoPages reloads the transitions) gets a new
        // node, so then by its place, as long as no row came or went (SUWA-17 C4)
        if
            let anchorPath, let oldAnchorY,
            let newIndexPath = anchorIdentifier.flatMap({ identifier in
                itemIdentifiers.first(where: { $0.value == identifier })?.key
            }) ?? (oldItemCounts == itemCounts ? anchorPath : nil),
            let newAnchorY = currentAttributes[newIndexPath]?.frame.minY,
            abs(newAnchorY - oldAnchorY) > 0.01
        {
            UIView.performWithoutAnimation {
                let offset = CGPoint(
                    x: collectionView.contentOffset.x,
                    y: collectionView.contentOffset.y + newAnchorY - oldAnchorY
                )
                collectionView.contentOffset = offset
                onOffsetPreserved?(offset)
            }
        }
    }

    func itemIdentifier(for indexPath: IndexPath) -> AnyHashable? {
        guard
            let collectionView = collectionView as? ASCollectionView,
            let node = collectionView.collectionNode?.nodeForItem(at: indexPath)
        else { return nil }
        return ObjectIdentifier(node)
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
        // right after a width change, the offset that keeps the middle page (SUWA-17 H)
        if let offset = widthChangeOffset {
            return offset
        }
        return preservedContentOffset() ?? proposedContentOffset
    }

    /// The content offset that puts the preserved anchor back at the center of the current bounds
    /// (upstream #1116; also what a size transition restores when it completes).
    func preservedContentOffset() -> CGPoint? {
        guard let collectionView, let anchor = preservedViewportAnchor else { return nil }
        let indexPath: IndexPath? = anchor.indexPath
        guard let indexPath, let attributes = layoutAttributesForItem(at: indexPath) else { return nil }

        let frame = attributes.frame
        let size = collectionView.bounds.size
        let inset = collectionView.adjustedContentInset
        let minimum = CGPoint(x: -inset.left, y: -inset.top)
        let maximum = CGPoint(
            x: max(minimum.x, collectionViewContentSize.width - size.width + inset.right),
            y: max(minimum.y, collectionViewContentSize.height - size.height + inset.bottom)
        )

        return CGPoint(
            x: min(max(frame.minX + frame.width * anchor.position.x - size.width / 2, minimum.x), maximum.x),
            y: min(max(frame.minY + frame.height * anchor.position.y - size.height / 2, minimum.y), maximum.y)
        )
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
