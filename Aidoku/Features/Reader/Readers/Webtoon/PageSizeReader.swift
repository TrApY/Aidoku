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

    /// An archive opened with its entries by path: a chapter's pages are measured opening it once, not once a page
    /// with a walk through all its entries (SUWA-17 E5). Extracting from it is one at a time.
    private final class OpenedArchive: @unchecked Sendable {
        let archive: Archive
        let entries: [String: Entry]
        let lock = NSLock()

        init(_ archive: Archive) {
            self.archive = archive
            var entries: [String: Entry] = [:]
            for entry in archive where entries[entry.path] == nil {
                entries[entry.path] = entry
            }
            self.entries = entries
        }
    }

    /// The last archives opened (a chapter and the next one), by path, size and date: a new download is opened again.
    nonisolated(unsafe) private static var opened: [(key: String, archive: OpenedArchive)] = []

    private static func openedArchive(_ url: URL) -> OpenedArchive? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let key = "\(url.path)|\(size)|\(date)"
        return opensLock.withLock {
            if let found = opened.first(where: { $0.key == key }) {
                return found.archive
            }
            guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }
            opens += 1
            let new = OpenedArchive(archive)
            opened.removeAll { $0.key.hasPrefix(url.path + "|") }
            opened.insert((key, new), at: 0)
            if opened.count > 2 {
                opened.removeLast()
            }
            return new
        }
    }

    /// From an entry of an archive (a downloaded .cbz): only its first chunks are read, until the header is in.
    static func ratio(archive archiveURL: URL, path: String) -> CGFloat? {
        struct Enough: Error {}
        guard
            let opened = openedArchive(archiveURL),
            let entry = opened.entries[path]
        else { return nil }
        let source = CGImageSourceCreateIncremental(options)
        var data = Data()
        var found: CGFloat?
        opened.lock.lock()
        defer { opened.lock.unlock() }
        _ = try? opened.archive.extract(entry, bufferSize: 16 * 1024, skipCRC32: true) { chunk in
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

/// The ratios of the pages already shown, by image and image settings: their pages are made with their height.
/// Kept in memory and, between launches, in a file in Caches (SUWA-25): written a while after a change and at once
/// when the app goes to the background. Up to `limit` pages, the oldest go first. Nothing in Core Data, CloudKit or
/// UserDefaults; iOS may empty Caches, and then the pages are measured again as before.
final class PageRatioMemory: @unchecked Sendable {
    static let shared = PageRatioMemory(fileURL: defaultFileURL)

    /// Where the shared store keeps its ratios between launches (SUWA-25).
    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PageRatios.plist")
    }

    private let lock = NSLock()
    private var ratios: [String: CGFloat] = [:]
    private var order: [String] = []
    private let limit: Int
    private let fileURL: URL?
    private let saveDelay: TimeInterval
    /// The file is read on first use, not when the store is made (the shared one is made early).
    private var loaded = false
    private var saveScheduled = false
    /// Writes one at a time, in order.
    private let writer = DispatchQueue(label: "PageRatioMemory.writer", qos: .utility)
    private var observer: NSObjectProtocol?
    private let center: NotificationCenter

    /// - fileURL: the file the ratios are kept in between launches (nil: memory only).
    /// - limit: how many pages it keeps, the oldest go first.
    /// - saveDelay: how long after a change it is written.
    /// - center: where it hears the app going to the background (then it is written at once).
    init(fileURL: URL? = nil, limit: Int = 5000, saveDelay: TimeInterval = 10, center: NotificationCenter = .default) {
        self.fileURL = fileURL
        self.limit = max(1, limit)
        self.saveDelay = saveDelay
        self.center = center
        guard fileURL != nil else { return }
        // the name's raw value: UIApplication's constant is the main actor's
        observer = center.addObserver(
            forName: Notification.Name("UIApplicationDidEnterBackgroundNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.saveNow()
        }
    }

    deinit {
        if let observer {
            center.removeObserver(observer)
        }
    }

    subscript(key: String) -> CGFloat? {
        lock.withLock {
            loadIfNeeded()
            return ratios[key]
        }
    }

    func set(_ ratio: CGFloat, for key: String) {
        let changed: Bool = lock.withLock {
            loadIfNeeded()
            let old = ratios.updateValue(ratio, forKey: key)
            if old == nil {
                order.append(key)
                trim()
            }
            return old != ratio
        }
        if changed {
            scheduleSave()
        }
    }

    /// Writes the ratios to the file now.
    func saveNow() {
        guard fileURL != nil else { return }
        writer.sync { write() }
    }

    // MARK: - File

    private static let version = 1

    /// What the file holds: the keys oldest first and their ratios.
    private struct Stored: Codable {
        let version: Int
        let keys: [String]
        let ratios: [Double]
    }

    /// Under the lock.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard
            let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
            stored.version == Self.version,
            stored.keys.count == stored.ratios.count
        else { return } // missing or unreadable: start empty
        let (keys, values) = (stored.keys, stored.ratios)
        // the file's (older) first, then whatever was set before the first read
        let earlier = order.map { ($0, ratios[$0]) }
        ratios = [:]
        order = []
        for (key, value) in zip(keys, values) where value.isFinite && value > 0 && ratios[key] == nil {
            ratios[key] = CGFloat(value)
            order.append(key)
        }
        for case let (key, value?) in earlier {
            if ratios.updateValue(value, forKey: key) == nil {
                order.append(key)
            }
        }
        trim()
    }

    /// Under the lock.
    private func trim() {
        if order.count > limit {
            for key in order.prefix(order.count - limit) {
                ratios[key] = nil
            }
            order.removeFirst(order.count - limit)
        }
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        let schedule: Bool = lock.withLock {
            guard !saveScheduled else { return false }
            saveScheduled = true
            return true
        }
        guard schedule else { return }
        writer.asyncAfter(deadline: .now() + saveDelay) { [weak self] in
            self?.write()
        }
    }

    /// On the writer queue.
    private func write() {
        guard let fileURL else { return }
        let (keys, values): ([String], [Double]) = lock.withLock {
            loadIfNeeded()
            saveScheduled = false
            return (order, order.map { Double(ratios[$0] ?? 0) })
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Stored(version: Self.version, keys: keys, ratios: values)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
