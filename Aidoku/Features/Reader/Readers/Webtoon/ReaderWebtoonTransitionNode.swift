//
//  ReaderWebtoonTransitionNode.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 3/22/23.
//

import AsyncDisplayKit

class ReaderWebtoonTransitionNode: BaseObservingCellNode {
    let transition: Transition
    let pillarboxLayoutState: ReaderPillarboxLayoutState

    var pillarbox = UserDefaults.standard.bool(forKey: "Reader.pillarbox")
    var pillarboxPortrait = CGFloat(UserDefaults.standard.double(forKey: PillarboxSettings.portraitKey))
    var pillarboxLandscape = CGFloat(UserDefaults.standard.double(forKey: PillarboxSettings.landscapeKey))

    private lazy var transitionNode = ReaderTransitionNode(transition: transition)

    init(transition: Transition, pillarboxLayoutState: ReaderPillarboxLayoutState) {
        self.transition = transition
        self.pillarboxLayoutState = pillarboxLayoutState

        super.init()

        automaticallyManagesSubnodes = true

        addObserver(forName: "Reader.pillarbox") { [weak self] notification in
            self?.pillarbox = notification.object as? Bool ?? false
        }
        addObserver(forName: PillarboxSettings.portraitKey) { [weak self] notification in
            self?.pillarboxPortrait = PillarboxSettings.value(from: notification.object, key: PillarboxSettings.portraitKey)
        }
        addObserver(forName: PillarboxSettings.landscapeKey) { [weak self] notification in
            self?.pillarboxLandscape = PillarboxSettings.value(from: notification.object, key: PillarboxSettings.landscapeKey)
        }
    }

    /// Width fraction for the current orientation, or nil without pillarbox.
    func pillarboxPercent() -> CGFloat? {
        PillarboxSettings.widthFraction(
            enabled: pillarbox,
            isPortrait: pillarboxLayoutState.isPortrait,
            portrait: pillarboxPortrait,
            landscape: pillarboxLandscape
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        transitionNode.referenceWidth = constrainedSize.max.width

        if let percent = pillarboxPercent() {
            let height = constrainedSize.max.width * percent

            transitionNode.style.width = ASDimensionMakeWithFraction(percent)
            transitionNode.style.height = ASDimensionMakeWithPoints(height)
            transitionNode.style.alignSelf = .center

            return ASCenterLayoutSpec(
                horizontalPosition: .center,
                verticalPosition: .center,
                sizingOption: [],
                child: transitionNode
            )
        } else {
            return ASRatioLayoutSpec(ratio: 1, child: transitionNode)
        }
    }
}
