//
//  ReaderWebtoonPreloadTests.swift
//  AidokuTests
//
//  SUWA-17 C (JoTa, 16-nov): «si hay una opción de precargar páginas, ¿por qué el webtoon sigue cargando y
//  reacomodando al bajar, incluso con el capítulo descargado?». Through the real ReaderViewController and webtoon
//  reader: how many pages below the one on screen already have their real height, with the chapter downloaded
//  (files) and from the server (slow loader); and what the «pages to preload» setting does there.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Nuke
import Testing
import UIKit

@testable import Aidoku

extension ImagePipelineSwappingTests {
@MainActor
@Suite(.serialized) struct ReaderWebtoonPreloadTests {
    static let pageCount = 16
    static let width: CGFloat = 402

    /// Page sizes in pixels: taller and shorter than the provisional height (ratio 1.435), none equal to it.
    static func size(of index: Int) -> CGSize {
        switch index % 4 {
            case 0: CGSize(width: 720, height: 2200)
            case 1: CGSize(width: 720, height: 1600)
            case 2: CGSize(width: 720, height: 700)
            default: CGSize(width: 720, height: 2600)
        }
    }

    /// The height of row `index` on screen once its image is known.
    static func realHeight(of index: Int) -> CGFloat {
        let size = size(of: index)
        return width * size.height / size.width
    }

    private static func pages(sourceKey: String, chapterKey: String, in directory: URL, remote: Bool) throws -> [Aidoku.Page] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<pageCount {
            let size = size(of: index)
            let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.7) { context in
                for band in 0..<Int(size.height / 100) + 1 {
                    UIColor(hue: CGFloat((index * 29 + band) % 97) / 97, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: CGFloat(band) * 100, width: size.width, height: 100))
                }
            }
            let url = directory.appendingPathComponent("\(chapterKey)-\(index).jpg")
            try data.write(to: url)
            let address = remote ? SlowImageLoader.serverURL(url) : url.absoluteString
            pages.append(Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, imageURL: address))
        }
        return pages
    }

    enum Kind {
        /// The chapter is downloaded: its pages are files, read straight from the disk (as the app does).
        case downloaded
        /// From the server: each image comes `delay` seconds after the previous one, two at a time.
        case remote(delay: Double)
    }

    @MainActor
    struct Opened {
        let reader: ReaderViewController
        let webtoon: ReaderWebtoonViewController
        let chapterIds: [ChapterIdentifier]
        let window: UIWindow
        let directory: URL
        let modeKey: String
        let pipeline: ImagePipeline
        let preload: Int
        let dataCache: DataCache?

        func close() async {
            window.isHidden = true
            ImagePipeline.shared = pipeline
            dataCache?.removeAll()
            dataCache.map { try? FileManager.default.removeItem(at: $0.path) }
            UserDefaults.standard.removeObject(forKey: modeKey)
            UserDefaults.standard.set(preload, forKey: "Reader.pagesToPreload")
            try? FileManager.default.removeItem(at: directory)
            for id in chapterIds {
                await removeTestHistory(id)
            }
        }

        var layout: UICollectionViewLayout { webtoon.collectionNode.collectionViewLayout }
        var top: CGFloat { webtoon.collectionNode.contentOffset.y }
        var bottom: CGFloat { top + webtoon.collectionNode.bounds.height }

        func frame(_ row: Int) -> CGRect? {
            layout.layoutAttributesForItem(at: IndexPath(row: row, section: 0))?.frame
        }

        /// The rows of the chapter's pages (row 0 is the transition before it).
        var pageRows: Range<Int> { 1..<(1 + ReaderWebtoonPreloadTests.pageCount) }

        func isMeasured(_ row: Int) -> Bool {
            guard let frame = frame(row) else { return false }
            return abs(frame.height - ReaderWebtoonPreloadTests.realHeight(of: row - 1)) < 1
        }

        /// The last row with any of it on screen.
        var lastVisibleRow: Int? {
            pageRows.last { (frame($0)?.minY ?? .infinity) < bottom }
        }

        /// How many rows right after the screen already have their real height.
        var measuredBelow: Int {
            guard let last = lastVisibleRow else { return 0 }
            var count = 0
            for row in (last + 1)..<pageRows.upperBound {
                guard isMeasured(row) else { break }
                count += 1
            }
            return count
        }

        /// The page nodes holding a decoded image now.
        var decodedImages: Int {
            pageRows.filter { (webtoon.collectionNode.nodeForItem(at: IndexPath(row: $0, section: 0)) as? ReaderWebtoonPageNode)?.image != nil }.count
        }
    }

    func open(_ kind: Kind, mangaKey: String, preload: Int = 2) async throws -> Opened {
        let first = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let second = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)
        let manga = AidokuRunner.Manga(sourceKey: "lectorprecarga", key: mangaKey, title: "Webtoon", chapters: [second, first])
        let ids = [first, second].map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: $0.key) }
        for id in ids {
            await removeTestHistory(id)
        }
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let savedPreload = UserDefaults.standard.integer(forKey: "Reader.pagesToPreload")
        UserDefaults.standard.set(preload, forKey: "Reader.pagesToPreload")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("precarga-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let remote = if case .remote = kind { true } else { false }
        let pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: first.key, in: directory, remote: remote)
        let nextPages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: second.key, in: directory, remote: remote)

        let pipeline = ImagePipeline.shared
        var dataCaches: [DataCache] = []
        switch kind {
            case .downloaded:
                // as the app's pipeline, with empty caches
                ImagePipeline.shared = ImagePipeline {
                    $0.imageCache = Nuke.ImageCache()
                }
            case .remote(let delay):
                let loader = SlowImageLoader(delay: delay)
                // as the app's pipeline: the server's data stays in a disk cache (this test's own, emptied after)
                let dataCache = try DataCache(name: "precarga-\(UUID().uuidString)")
                dataCaches.append(dataCache)
                ImagePipeline.shared = ImagePipeline {
                    $0.dataLoader = loader
                    $0.isLocalResourcesSupportEnabled = false
                    $0.imageCache = Nuke.ImageCache()
                    $0.dataCache = dataCache
                    $0.dataCachePolicy = .storeOriginalData
                }
        }
        let reader = ReaderViewController(source: nil, manga: manga, chapter: first)
        reader.appActivity = ReaderAppActivity(center: NotificationCenter(), active: true)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: Self.width, height: 874)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let webtoon = try #require(reader.reader as? ReaderWebtoonViewController, "not the webtoon reader")
        reader.presentedViewController?.dismiss(animated: false)
        webtoon.viewModel.preloadedChapter = first
        webtoon.viewModel.preloadedPages = pages
        reader.loadCurrentChapter()
        // the chapter's rows are in (frame by frame, so the opening is seen), then the next chapter is ready
        for _ in 0..<400 where webtoon.collectionNode.numberOfSections == 0
            || webtoon.collectionNode.numberOfItems(inSection: 0) < Self.pageCount {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(webtoon.chapter?.key == first.key && webtoon.collectionNode.numberOfItems(inSection: 0) > Self.pageCount)
        webtoon.viewModel.preloadedChapter = second
        webtoon.viewModel.preloadedPages = nextPages
        return Opened(
            reader: reader, webtoon: webtoon, chapterIds: ids, window: window, directory: directory, modeKey: modeKey,
            pipeline: pipeline, preload: savedPreload, dataCache: dataCaches.first
        )
    }

    /// The rows whose height changed between two looks while any of them was on screen or above it.
    @MainActor
    final class Heights {
        var last: [Int: CGFloat] = [:]
        var changes: [String] = []

        func look(_ opened: Opened, _ when: String) {
            for row in opened.pageRows {
                guard let frame = opened.frame(row) else { continue }
                if let before = last[row], abs(before - frame.height) >= 1, frame.minY < opened.bottom {
                    changes.append("\(when): fila \(row) \(Int(before)) → \(Int(frame.height)) (arriba \(Int(frame.minY - opened.top)))")
                }
                last[row] = frame.height
            }
        }
    }

    /// Down at `velocity` points a second for `seconds`, a frame at a time, looking at every frame.
    func scroll(_ opened: Opened, seconds: Double, velocity: CGFloat, every: (String) -> Void) async throws {
        let scrollView = opened.webtoon.scrollView
        opened.webtoon.scrollViewWillBeginDragging(scrollView)
        var clock = ContinuousClock.now
        let start = clock
        var index = 0
        while ContinuousClock.now - start < .milliseconds(Int(seconds * 1000)) {
            try await Task.sleep(for: .milliseconds(16))
            let now = ContinuousClock.now
            let elapsed = now - clock
            clock = now
            let step = velocity * (CGFloat(elapsed.components.seconds) + CGFloat(elapsed.components.attoseconds) / 1e18)
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.contentOffset = CGPoint(x: 0, y: min(scrollView.contentOffset.y + step, maxY))
            every("bajando \(index)")
            index += 1
        }
        opened.webtoon.scrollViewDidEndDragging(scrollView, willDecelerate: false)
    }

    /// Waits up to `seconds` for the first look, checking every frame.
    func watch(_ opened: Opened, seconds: Double, every: (String) -> Void) async throws {
        let start = ContinuousClock.now
        var index = 0
        while ContinuousClock.now - start < .milliseconds(Int(seconds * 1000)) {
            try await Task.sleep(for: .milliseconds(16))
            every("quieto \(index)")
            index += 1
        }
    }
}
}

// MARK: - P1: what is measured below the screen (the numbers go to SUWA17_MEDIDAS, a file; nothing asserted)
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    private static let report = ProcessInfo.processInfo.environment["SUWA17_MEDIDAS"].map { URL(fileURLWithPath: $0) }

    private func note(_ line: String) {
        guard let report = Self.report else { return }
        let old = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        try? (old + line + "\n").write(to: report, atomically: true, encoding: .utf8)
    }

    private func measure(_ kind: Kind, name: String, preload: Int) async throws {
        let opened = try await open(kind, mangaKey: "medir-\(name)-\(preload)", preload: preload)
        let heights = Heights()
        var maxDecoded = 0
        var belowWhileScrolling: [Int] = []
        try await watch(opened, seconds: 4) { when in
            heights.look(opened, when)
            maxDecoded = max(maxDecoded, opened.decodedImages)
        }
        let atRest = opened.measuredBelow
        let openingChanges = heights.changes.count
        try await scroll(opened, seconds: 4, velocity: 1500) { when in
            heights.look(opened, when)
            maxDecoded = max(maxDecoded, opened.decodedImages)
            belowWhileScrolling.append(opened.measuredBelow)
        }
        let scrollingChanges = heights.changes.count - openingChanges
        try await watch(opened, seconds: 3) { when in
            heights.look(opened, when)
            maxDecoded = max(maxDecoded, opened.decodedImages)
        }
        let afterRest = opened.measuredBelow
        let lowest = belowWhileScrolling.min() ?? -1
        let average = belowWhileScrolling.isEmpty ? 0 : Double(belowWhileScrolling.reduce(0, +)) / Double(belowWhileScrolling.count)
        note(
            "\(name) precarga=\(preload): medidas por debajo al abrir=\(atRest), bajando mín=\(lowest) media=\(String(format: "%.1f", average)), "
                + "parado después=\(afterRest) | cambios de altura en pantalla o encima: al abrir \(openingChanges), bajando \(scrollingChanges) "
                + "| imágenes decodificadas a la vez (máx) \(maxDecoded)"
        )
        for change in heights.changes.prefix(6) {
            note("    \(change)")
        }
        await opened.close()
    }

    @Test func measureDownloaded() async throws {
        try await measure(.downloaded, name: "descargado", preload: 2)
    }

    @Test func measureRemote() async throws {
        try await measure(.remote(delay: 0.3), name: "remoto", preload: 2)
    }

    @Test func measureRemoteWithMorePreload() async throws {
        try await measure(.remote(delay: 0.3), name: "remoto", preload: 6)
    }
}

// MARK: - P2, P3: measured before showing, the setting deciding how far, memory
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// P3: a downloaded chapter, opened and scrolled down quickly: no page changes height on screen or above it
    /// (its height comes from the file's header when the page is made).
    @Test func aDownloadedChapterNeverChangesAPageHeightOnScreenOrAbove() async throws {
        let opened = try await open(.downloaded, mangaKey: "descargado", preload: 2)
        let heights = Heights()
        try await watch(opened, seconds: 3) { heights.look(opened, $0) }
        try await scroll(opened, seconds: 4, velocity: 1500) { heights.look(opened, $0) }
        try await watch(opened, seconds: 2) { heights.look(opened, $0) }
        #expect(heights.changes.isEmpty, "\(heights.changes.prefix(4))")
        await opened.close()
    }
}
