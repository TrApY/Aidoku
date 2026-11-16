//
//  ReaderWebtoonScrollDownTests.swift
//  AidokuTests
//
//  SUWA-17 C5 (JoTa, 16-nov): «a veces, desplazándome hacia abajo en webtoon, en lugar de cargar la página
//  siguiente me vuelve a alguna página anterior». Through the real ReaderViewController and webtoon reader, with
//  real images much taller than the provisional height that load while the user scrolls down (dragging, a fling
//  decelerating, and up to the end where the next chapter goes in below): what is on screen never goes back.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Nuke
import Testing
import UIKit

@testable import Aidoku

/// The images come as from the server over the network: two at a time, each one `delay` seconds after the
/// previous one in its slot, not from the disk at once (so the loaded pages fall behind a quick scroll).
final class SlowImageLoader: DataLoading, @unchecked Sendable {
    let delay: Double
    private let lock = NSLock()
    private var slots: [DispatchTime] = [.now(), .now()]

    init(delay: Double) {
        self.delay = delay
    }

    private final class Work: Cancellable, @unchecked Sendable {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    /// Pages from this index on wait until `release()` (a server that has not sent them yet).
    var heldFrom = Int.max
    private var held: [DispatchWorkItem] = []

    func release() {
        lock.lock()
        let items = held
        held = []
        heldFrom = Int.max
        lock.unlock()
        for item in items {
            DispatchQueue.global().async(execute: item)
        }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let item = DispatchWorkItem {
            guard let url = request.url, let data = try? Data(contentsOf: url) else {
                completion(URLError(.cannotOpenFile))
                return
            }
            didReceiveData(data, URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
            completion(nil)
        }
        let index = request.url?.deletingPathExtension().lastPathComponent.split(separator: "-").last.flatMap { Int($0) } ?? 0
        lock.lock()
        if index >= heldFrom {
            held.append(item)
            lock.unlock()
            return Work(item)
        }
        let slot = slots[0] < slots[1] ? 0 : 1
        let deadline = max(slots[slot], .now()) + delay
        slots[slot] = deadline
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: item)
        return Work(item)
    }
}

@MainActor
@Suite(.serialized) struct ReaderWebtoonScrollDownTests {
    private static let pageCount = 16

    private static func pages(sourceKey: String, chapterKey: String, in directory: URL) throws -> [Aidoku.Page] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<pageCount {
            // much taller than the provisional height (ratio 1.435): about 2.1 times it on screen
            let size = CGSize(width: 720, height: index % 2 == 0 ? 2200 : 2100)
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                for band in 0..<22 {
                    UIColor(hue: CGFloat((index * 22 + band) % 97) / 97, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: CGFloat(band) * 100, width: size.width, height: 100))
                }
            }
            let url = directory.appendingPathComponent("\(chapterKey)-\(index).png")
            try data.write(to: url)
            pages.append(Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, imageURL: url.absoluteString))
        }
        return pages
    }

    /// Where the reading is: the chapter, the row in the middle of the screen and how far its top is above the
    /// top of the screen (it grows as the user goes down; a page growing does not move its own top, so only the
    /// content moving counts).
    struct Position: Comparable, CustomStringConvertible {
        let chapter: Int
        let row: Int
        let scrolledInto: CGFloat

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.chapter, lhs.row) != (rhs.chapter, rhs.row)
                ? (lhs.chapter, lhs.row) < (rhs.chapter, rhs.row)
                : lhs.scrolledInto < rhs.scrolledInto
        }

        var description: String { "c\(chapter + 1) fila \(row) +\(Int(scrolledInto))" }
    }

    @MainActor
    private struct Opened {
        let reader: ReaderViewController
        let webtoon: ReaderWebtoonViewController
        let chapterIds: [ChapterIdentifier]
        let window: UIWindow
        let directory: URL
        let modeKey: String
        let pipeline: ImagePipeline
        let loader: SlowImageLoader

        func close() async {
            window.isHidden = true
            ImagePipeline.shared = pipeline
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
            for id in chapterIds {
                await removeTestHistory(id)
            }
        }

        var position: Position? {
            guard
                let middle = webtoon.getCurrentPagePath(),
                let frame = webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: middle)?.frame,
                frame.height > 0
            else { return nil }
            let chapter = webtoon.chapter?.key == "c2" ? 1 : 0
            // the section of the middle row is the reader's chapter (it switches as soon as the middle crosses)
            let middleY = webtoon.collectionNode.contentOffset.y + webtoon.collectionNode.bounds.height / 2
            _ = middleY
            return Position(chapter: chapter, row: middle.row, scrolledInto: webtoon.collectionNode.contentOffset.y - frame.minY)
        }
    }

    /// Opens chapter 1 (with chapter 2 after it) at its first page, with the next chapter's pages ready.
    private func open(mangaKey: String, heldFrom: Int = .max) async throws -> Opened {
        let first = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let second = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)
        let manga = AidokuRunner.Manga(sourceKey: "lectorbajar", key: mangaKey, title: "Webtoon", chapters: [second, first])
        let ids = [first, second].map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key) }
        for id in ids {
            await removeTestHistory(id)
        }
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bajar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: first.key, in: directory)
        let nextPages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: second.key, in: directory)

        let pipeline = ImagePipeline.shared
        let loader = SlowImageLoader(delay: 1.2)
        loader.heldFrom = heldFrom
        ImagePipeline.shared = ImagePipeline {
            $0.dataLoader = loader
            // the pages are files here; on the device they come from the server through the loader
            $0.isLocalResourcesSupportEnabled = false
            $0.imageCache = nil
        }
        let reader = ReaderViewController(source: nil, manga: manga, chapter: first)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let webtoon = try #require(reader.reader as? ReaderWebtoonViewController, "not the webtoon reader")
        reader.presentedViewController?.dismiss(animated: false)
        webtoon.viewModel.preloadedChapter = first
        webtoon.viewModel.preloadedPages = pages
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(4))
        // what the reader gets when it asks for the next chapter
        webtoon.viewModel.preloadedChapter = second
        webtoon.viewModel.preloadedPages = nextPages
        return Opened(
            reader: reader, webtoon: webtoon, chapterIds: ids, window: window, directory: directory, modeKey: modeKey, pipeline: pipeline, loader: loader
        )
    }

    /// One frame of the scroll at `velocity` points a second for the time the frame really took: the scroll view
    /// moves on from where it is now (as UIKit does, also while decelerating), up to the end of its content.
    private func frame(_ opened: Opened, velocity: CGFloat, clock: inout ContinuousClock.Instant) async throws {
        try await Task.sleep(for: .milliseconds(16))
        let now = ContinuousClock.now
        let elapsed = now - clock
        clock = now
        let seconds = CGFloat(elapsed.components.seconds) + CGFloat(elapsed.components.attoseconds) / 1e18
        let scrollView = opened.webtoon.scrollView
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.contentOffset = CGPoint(x: 0, y: min(scrollView.contentOffset.y + velocity * seconds, maxY))
    }

    /// The positions seen, one per frame; the backward steps among them (with a 1 pt allowance).
    @MainActor
    private final class Track {
        var positions: [Position] = []
        var backwards: [String] = []

        var log: [String] = []

        var webtoon: ReaderWebtoonViewController?

        func note(_ position: Position?, _ when: String) {
            var above = ""
            if let webtoon {
                let top = webtoon.collectionNode.contentOffset.y
                let layout = webtoon.collectionNode.collectionViewLayout
                let rows = (0..<webtoon.collectionNode.numberOfItems(inSection: 0)).filter {
                    guard let frame = layout.layoutAttributesForItem(at: IndexPath(row: $0, section: 0))?.frame else { return false }
                    return frame.maxY < top && Int(frame.height) == 576
                }
                above = " y=\(Int(top)) provisionales-encima=\(rows)"
            }
            log.append("\(when) \(position.map(\.description) ?? "nil")\(above)")
            guard let position else { return }
            if let last = positions.last, position < last, !(position.chapter == last.chapter && position.row == last.row
                && last.scrolledInto - position.scrolledInto < 1) {
                backwards.append("\(when): \(last) → \(position)")
            }
            positions.append(position)
        }
    }

    /// The user drags down steadily at `velocity` points a second for `seconds`, then lets go.
    private func drag(_ opened: Opened, seconds: Double, velocity: CGFloat, track: Track) async throws {
        opened.webtoon.scrollViewWillBeginDragging(opened.webtoon.scrollView)
        var clock = ContinuousClock.now
        let start = clock
        var index = 0
        while ContinuousClock.now - start < .milliseconds(Int(seconds * 1000)) {
            try await frame(opened, velocity: velocity, clock: &clock)
            track.note(opened.position, "arrastre \(index)")
            index += 1
        }
        opened.webtoon.scrollViewDidEndDragging(opened.webtoon.scrollView, willDecelerate: false)
    }

    /// The user lets go at `velocity` points a second; the scroll decelerates as UIKit's normal rate does
    /// (×0.998 a millisecond) until it stops.
    private func fling(_ opened: Opened, velocity: CGFloat, track: Track) async throws {
        opened.webtoon.scrollViewWillBeginDragging(opened.webtoon.scrollView)
        var clock = ContinuousClock.now
        for index in 0..<4 {
            try await frame(opened, velocity: velocity, clock: &clock)
            track.note(opened.position, "arrastre \(index)")
        }
        opened.webtoon.scrollViewDidEndDragging(opened.webtoon.scrollView, willDecelerate: true)
        let start = ContinuousClock.now
        var index = 0
        var current = velocity
        while current > 20 {
            try await frame(opened, velocity: current, clock: &clock)
            track.note(opened.position, "deceleración \(index)")
            let elapsed = ContinuousClock.now - start
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            current = velocity * CGFloat(pow(0.998, milliseconds))
            index += 1
        }
        opened.webtoon.scrollViewDidEndDecelerating(opened.webtoon.scrollView)
    }

    /// Nobody touches anything for `seconds`: the images keep loading, and nothing on screen may go back.
    private func idle(_ opened: Opened, seconds: Double, track: Track) async throws {
        let frames = Int(seconds * 1000 / 50)
        for index in 0..<frames {
            try await Task.sleep(for: .milliseconds(50))
            track.note(opened.position, "quieto \(index)")
        }
    }

    /// The server has not sent pages 7 on when the user scrolls quickly past them (they keep the provisional
    /// height); they arrive once they are above the screen and grow there: what is being read stays put.
    @Test func pagesPassedBeforeTheyLoadedGrowAboveWithoutMovingTheScreen() async throws {
        let opened = try await open(mangaKey: "pasadas", heldFrom: 7)
        let track = Track()
        track.webtoon = opened.webtoon
        track.note(opened.position, "inicio")
        try await drag(opened, seconds: 4.2, velocity: 2500, track: track)
        try await idle(opened, seconds: 1, track: track)
        let passed = track.log.last ?? ""
        opened.loader.release()
        try await idle(opened, seconds: 4, track: track)
        #expect(passed.contains("8, 9, 10"), "the held pages were not passed: \(passed)")
        #expect(track.backwards.isEmpty, "\(track.backwards.prefix(6))")
        await opened.close()
    }

    @Test func draggingDownWhilePagesLoadNeverGoesBack() async throws {
        let opened = try await open(mangaKey: "arrastrar")
        let track = Track()
        track.webtoon = opened.webtoon
        track.note(opened.position, "inicio")
        // a quick steady drag (about 3000 pt/s) through pages whose images are still loading
        try await drag(opened, seconds: 4, velocity: 2500, track: track)
        try await idle(opened, seconds: 5, track: track)
        #expect(track.backwards.isEmpty, "\(track.backwards.prefix(6))")
        #expect((track.positions.last?.row ?? 0) > 3, "did not move: \(String(describing: track.positions.last))")
        await opened.close()
    }

    @Test func aFlingDeceleratingWhilePagesLoadNeverGoesBack() async throws {
        let opened = try await open(mangaKey: "lanzar")
        let track = Track()
        track.webtoon = opened.webtoon
        track.note(opened.position, "inicio")
        // a fling at 12000 pt/s decelerating as UIKit does, while the pages it passes are still loading
        try await fling(opened, velocity: 12000, track: track)
        try await idle(opened, seconds: 5, track: track)
        #expect(track.backwards.isEmpty, "\(track.backwards.prefix(6))")
        #expect((track.positions.last?.row ?? 0) > 3, "did not move: \(String(describing: track.positions.last))")
        await opened.close()
    }

    @Test func toTheEndAndIntoTheNextChapterNeverGoesBack() async throws {
        let opened = try await open(mangaKey: "alfinal")
        let track = Track()
        track.webtoon = opened.webtoon
        track.note(opened.position, "inicio")
        // down in several drags with pauses (the next chapter goes in below once the scroll stops)
        for round in 0..<10 {
            try await fling(opened, velocity: 4000, track: track)
            try await idle(opened, seconds: 1.5, track: track)
            _ = round
        }
        try await idle(opened, seconds: 2, track: track)
        #expect(track.backwards.isEmpty, "\(track.backwards.prefix(6))")
        #expect(opened.webtoon.collectionNode.numberOfSections >= 2, "the next chapter was not put in")
        await opened.close()
    }
}

// MARK: - The anchor of the layout (SUWA-17 C3, C4)
extension ReaderWebtoonScrollDownTests {
    private var layoutOf: (Opened) -> VerticalContentOffsetPreservingLayout? {
        { $0.webtoon.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout }
    }

    /// Where the top of `row` is on screen.
    private func topOnScreen(_ opened: Opened, row: Int) -> CGFloat? {
        opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: 0))
            .map { $0.frame.minY - opened.webtoon.collectionNode.contentOffset.y }
    }

    /// The user drags until the middle of the screen is in `row`, and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int) throws {
        let webtoon = opened.webtoon
        let frame = try #require(webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: 0))?.frame)
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: frame.midY - webtoon.collectionNode.bounds.height / 2), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
    }

    /// C3: a layout pass in which nothing moved leaves the scroll view alone (no offset, no content size set:
    /// every pass did it, also while pinching).
    @Test func aLayoutPassWithNothingChangedLeavesTheScrollViewAlone() async throws {
        let opened = try await open(mangaKey: "nada")
        try userScrolls(opened, toRow: 3)
        try await Task.sleep(for: .seconds(4))
        let layout = try #require(layoutOf(opened))
        let original = layout.onOffsetPreserved
        var calls = 0
        layout.onOffsetPreserved = { offset in
            calls += 1
            original?(offset)
        }
        for _ in 0..<3 {
            layout.invalidateLayout()
            opened.webtoon.collectionNode.view.layoutIfNeeded()
        }
        #expect(calls == 0, "the scroll view was set \(calls) times with nothing to make up for")
        layout.onOffsetPreserved = original
        await opened.close()
    }

    /// C3: zoomed in, the page in the middle and the one above it arrive (still loading when the user got there)
    /// and grow: the top of the page being read stays where it is on screen.
    @Test func zoomedInPagesGrowingAboveAndInTheMiddleDoNotMoveIt() async throws {
        let opened = try await open(mangaKey: "zoom", heldFrom: 3)
        opened.webtoon.scrollView.setZoomScale(2, animated: false)
        try await Task.sleep(for: .seconds(1))
        try #require(layoutOf(opened)?.getScale() == 2, "not zoomed in")
        try userScrolls(opened, toRow: 5)
        try await Task.sleep(for: .seconds(2))
        let before = try #require(topOnScreen(opened, row: 5))
        let heightBefore = opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 5, section: 0))?.frame.height ?? 0
        opened.loader.release()
        try await Task.sleep(for: .seconds(5))
        let heightAfter = opened.webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: 5, section: 0))?.frame.height ?? 0
        try #require(heightAfter > heightBefore + 100, "the page in the middle did not grow: \(heightBefore) → \(heightAfter)")
        let after = try #require(topOnScreen(opened, row: 5))
        #expect(abs(after - before) < 1, "the page being read moved \(after - before) pt on screen")
        await opened.close()
    }

    /// C4: rows reloaded (as refreshInfoPages reloads the transitions) get new nodes; when the row in the middle
    /// is one of them, the row above changing in the same pass (reloaded, back to its provisional height) must
    /// still be made up for.
    @Test func aRowReloadedTogetherWithTheMiddleOneKeepsTheScreen() async throws {
        let opened = try await open(mangaKey: "recargar")
        try userScrolls(opened, toRow: 6)
        try await Task.sleep(for: .seconds(5))
        let before = try #require(topOnScreen(opened, row: 6))
        let node = opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: 6, section: 0))
        await withCheckedContinuation { continuation in
            opened.webtoon.collectionNode.performBatchUpdates {
                opened.webtoon.collectionNode.reloadItems(at: [IndexPath(row: 5, section: 0), IndexPath(row: 6, section: 0)])
            } completion: { _ in
                continuation.resume()
            }
        }
        #expect(opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: 6, section: 0)) !== node, "the reload kept the node")
        try await Task.sleep(for: .milliseconds(300))
        let during = try #require(topOnScreen(opened, row: 6))
        #expect(abs(during - before) < 1, "right after the reload the page being read moved \(during - before) pt")
        try await Task.sleep(for: .seconds(4))
        let after = try #require(topOnScreen(opened, row: 6))
        #expect(abs(after - before) < 1, "once loaded again the page being read moved \(after - before) pt")
        await opened.close()
    }
}
