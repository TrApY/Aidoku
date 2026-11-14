//
//  HeightQueryable.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 3/23/23.
//

import UIKit

protocol HeightQueryable {
    func getHeight(for size: CGSize) -> CGFloat
}

extension ReaderWebtoonPageNode: HeightQueryable {
    func getHeight(for size: CGSize) -> CGFloat {
        guard size.width > 0 else { return 0 }

        let ratio = ratio ?? Self.defaultRatio

        if let percent = pillarboxPercent() {
            return size.width * percent * ratio
        }

        return size.width * ratio
    }
}

extension ReaderWebtoonTransitionNode: HeightQueryable {
    func getHeight(for size: CGSize) -> CGFloat {
        guard size.width > 0 else { return 0 }

        if let percent = pillarboxPercent() {
            return size.width * percent
        }

        return size.width
    }
}
