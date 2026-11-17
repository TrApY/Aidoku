//
//  PageSizeReader.swift
//  Aidoku
//
//  SUWA-17 C: the size of a page's image before it is shown, so that its cell is made with its real height
//  and does not grow or shrink on screen when the image is painted.
//

import Foundation
import ImageIO

/// The height/width ratio of an image from its header, without decoding it.
enum PageSizeReader {
    private static let options = [kCGImageSourceShouldCache: false] as CFDictionary

    static func ratio(fileURL: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else { return nil }
        return ratio(source)
    }

    static func ratio(data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return ratio(source)
    }

    private static func ratio(_ source: CGImageSource) -> CGFloat? {
        guard
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0
        else { return nil }
        // orientations 5 to 8 turn the image a quarter: UIImage swaps its sides
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? width / height : height / width
    }
}

/// The ratios of the pages already shown in this run, by image and image settings: the images in the cache
/// were shown, so their pages are made with their height. Kept in memory only, up to `limit` pages.
final class PageRatioMemory: @unchecked Sendable {
    static let shared = PageRatioMemory()

    private let lock = NSLock()
    private var ratios: [String: CGFloat] = [:]
    private var order: [String] = []
    private let limit = 2000

    subscript(key: String) -> CGFloat? {
        lock.withLock { ratios[key] }
    }

    func set(_ ratio: CGFloat, for key: String) {
        lock.withLock {
            guard ratios.updateValue(ratio, forKey: key) == nil else { return }
            order.append(key)
            if order.count > limit {
                ratios[order.removeFirst()] = nil
            }
        }
    }
}
