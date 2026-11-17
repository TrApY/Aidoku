//
//  PageSizeReader.swift
//  Aidoku
//
//  SUWA-17 C: the size of a page's image before it is shown, so that its cell is made with its real height
//  and does not grow or shrink on screen when the image is painted.
//

import Foundation
import ImageIO
import ZIPFoundation

/// The height/width ratio of an image from its header, without decoding it.
enum PageSizeReader {
    private static let opensLock = NSLock()
    nonisolated(unsafe) private static var opens = 0
    /// How many times an archive was opened to measure its pages (tests).
    static var archiveOpens: Int { opensLock.withLock { opens } }

    private static var options: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    static func ratio(fileURL: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else { return nil }
        return ratio(source)
    }

    static func ratio(data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return ratio(source)
    }

    /// From an entry of an archive (a downloaded .cbz): only its first chunks are read, until the header is in.
    static func ratio(archive archiveURL: URL, path: String) -> CGFloat? {
        struct Enough: Error {}
        guard
            let archive = try? Archive(url: archiveURL, accessMode: .read, pathEncoding: nil),
            let entry = archive[path]
        else { return nil }
        opensLock.withLock { opens += 1 }
        let source = CGImageSourceCreateIncremental(options)
        var data = Data()
        var found: CGFloat?
        _ = try? archive.extract(entry, bufferSize: 16 * 1024, skipCRC32: true) { chunk in
            data.append(chunk)
            CGImageSourceUpdateData(source, data as CFData, false)
            if let ratio = ratio(source) {
                found = ratio
                throw Enough()
            }
            // the header is at the start: no further than 1 MB
            if data.count > 1024 * 1024 {
                throw Enough()
            }
        }
        return found
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
