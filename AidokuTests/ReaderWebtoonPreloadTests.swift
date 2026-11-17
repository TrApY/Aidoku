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
import ZIPFoundation

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

    /// The pages put in a .cbz archive at `url`, as pages of it (DownloadManager.getDownloadedPages).
    private static func archived(_ pages: [Aidoku.Page], as url: URL) throws -> [Aidoku.Page] {
        let archive = try Archive(url: url, accessMode: .create)
        return try pages.map { page in
            guard let file = page.imageURL.flatMap(URL.init(string:)) else { throw URLError(.badURL) }
            try archive.addEntry(with: file.lastPathComponent, relativeTo: file.deletingLastPathComponent(), compressionMethod: .deflate)
            var page = page
            page.imageURL = file.lastPathComponent
            page.zipURL = url.absoluteString
            return page
        }
    }

    enum Kind {
        /// The chapter is downloaded: its pages are files, read straight from the disk (as the app does).
        case downloaded
        /// The chapter is downloaded as the app downloads it: a .cbz archive with its pages.
        case downloadedArchive
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
        let loader: SlowImageLoader?

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

        /// The rows with any of them on screen, or still on screen for Texture (its visible state follows the
        /// screen a moment later).
        var visibleRows: Int {
            pageRows.filter { row in
                if (webtoon.collectionNode.nodeForItem(at: IndexPath(row: row, section: 0)) as? ReaderWebtoonPageNode)?.isVisible == true {
                    return true
                }
                guard let frame = frame(row) else { return false }
                return frame.maxY > top + 0.5 && frame.minY < bottom - 0.5
            }.count
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
        var pages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: first.key, in: directory, remote: remote)
        var nextPages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: second.key, in: directory, remote: remote)
        if case .downloadedArchive = kind {
            pages = try Self.archived(pages, as: directory.appendingPathComponent("\(first.key).cbz"))
            nextPages = try Self.archived(nextPages, as: directory.appendingPathComponent("\(second.key).cbz"))
        }

        let pipeline = ImagePipeline.shared
        var dataCaches: [DataCache] = []
        var loaders: [SlowImageLoader] = []
        switch kind {
            case .downloaded, .downloadedArchive:
                // as the app's pipeline, with empty caches
                ImagePipeline.shared = ImagePipeline {
                    $0.imageCache = Nuke.ImageCache()
                }
            case .remote(let delay):
                let loader = SlowImageLoader(delay: delay)
                loaders.append(loader)
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
            pipeline: pipeline, preload: savedPreload, dataCache: dataCaches.first, loader: loaders.first
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

    /// P2: from the server, the «pages to preload» pages after the screen are loaded and measured while the user
    /// is still on the first one, and each page has its height before it shows.
    @Test func fromTheServerTheNextPagesAreMeasuredBeforeTheyShow() async throws {
        let opened = try await open(.remote(delay: 0.3), mangaKey: "remoto", preload: 4)
        try await watch(opened, seconds: 4) { _ in }
        #expect(opened.measuredBelow >= 4, "only \(opened.measuredBelow) pages below the screen measured")
        // the scroll view the user moves can go as far as the measured pages
        let content = opened.layout.collectionViewContentSize.height
        #expect(abs(opened.webtoon.scrollView.contentSize.height - content) < 1, "scroll content \(opened.webtoon.scrollView.contentSize.height), pages \(content)")
        var shownUnmeasured: [String] = []
        var shown: Set<Int> = []
        let look: (String) -> Void = { when in
            for row in opened.pageRows where !shown.contains(row) && (opened.frame(row)?.minY ?? .infinity) < opened.bottom {
                shown.insert(row)
                if !opened.isMeasured(row) {
                    shownUnmeasured.append("\(when): fila \(row) \(Int(opened.frame(row)?.height ?? 0))")
                }
            }
        }
        look("al abrir")
        try await scroll(opened, seconds: 9, velocity: 700, every: look)
        #expect(shown.count >= 7, "the scroll showed \(shown.count) pages")
        #expect(shownUnmeasured.isEmpty, "\(shownUnmeasured)")
        await opened.close()
    }

    /// P2 and memory: with more pages to preload than Texture's own range (it decodes the pages up to 2.5
    /// screens below), the ones further down get measured from their header without decoding them, and the
    /// decoded images at once stay within «pages to preload» + 2.
    @Test func measuringFarAheadDecodesNothingMore() async throws {
        let preload = 8
        let opened = try await open(.remote(delay: 0.3), mangaKey: "lejos", preload: preload)
        var maxDecoded = 0
        try await watch(opened, seconds: 6) { _ in maxDecoded = max(maxDecoded, opened.decodedImages) }
        #expect(opened.measuredBelow >= preload, "only \(opened.measuredBelow) pages below the screen measured")
        #expect(maxDecoded <= preload + 2, "\(maxDecoded) images decoded at once")
        let last = try #require(opened.lastVisibleRow)
        let screen = opened.webtoon.collectionNode.bounds.height
        let farRows = ((last + 1)...(last + preload)).filter { (opened.frame($0)?.minY ?? 0) > opened.bottom + 3 * screen }
        #expect(!farRows.isEmpty, "no page further than 3 screens within the \(preload) to preload")
        let decodedFar = farRows.filter { (opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: $0, section: 0)) as? ReaderWebtoonPageNode)?.image != nil }
        #expect(decodedFar.isEmpty, "rows \(decodedFar) of \(farRows), further than 3 screens, decoded")
        #expect(farRows.allSatisfy { opened.isMeasured($0) }, "rows \(farRows.filter { !opened.isMeasured($0) }) not measured")
        await opened.close()
    }

    /// P3: the same with the chapter downloaded as the app does it, a .cbz archive (each page's height from the
    /// header of its entry).
    @Test func aDownloadedArchiveChapterNeverChangesAPageHeightOnScreenOrAbove() async throws {
        let opened = try await open(.downloadedArchive, mangaKey: "cbz", preload: 2)
        let heights = Heights()
        try await watch(opened, seconds: 3) { heights.look(opened, $0) }
        try await scroll(opened, seconds: 4, velocity: 1500) { heights.look(opened, $0) }
        try await watch(opened, seconds: 2) { heights.look(opened, $0) }
        #expect(heights.changes.isEmpty, "\(heights.changes.prefix(4))")
        await opened.close()
    }
}

// MARK: - SUWA-17 E1: decoded images at once
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// Opened, still, scrolled down quickly and still again: never more pages hold a decoded image than «pages to
    /// preload» + 2, counting the ones on screen (more only while more than that are on screen at once).
    private func decodedStayWithin(_ preload: Int, _ kind: Kind, key: String) async throws {
        let opened = try await open(kind, mangaKey: key, preload: preload)
        var over: [String] = []
        var most = 0
        let look: (String) -> Void = { when in
            let limit = max(preload + 2, opened.visibleRows)
            let decoded = opened.decodedImages
            most = max(most, decoded)
            if decoded > limit, over.count < 6 {
                over.append("\(when): \(decoded) > \(limit)")
            }
        }
        try await watch(opened, seconds: 3, every: look)
        try await scroll(opened, seconds: 4, velocity: 1500, every: look)
        try await watch(opened, seconds: 2, every: look)
        #expect(over.isEmpty, "preload \(preload), most \(most): \(over)")
        #expect(most >= 1)
        await opened.close()
    }

    @Test func downloadedAtMostTwoMoreDecodedThanToPreload() async throws {
        try await decodedStayWithin(2, .downloaded, key: "decod2")
    }

    @Test func downloadedWithNothingToPreloadAtMostTwoDecoded() async throws {
        try await decodedStayWithin(0, .downloaded, key: "decod0")
    }

    @Test func fromTheServerAtMostTwoMoreDecodedThanToPreload() async throws {
        try await decodedStayWithin(2, .remote(delay: 0.3), key: "decod2r")
    }
}

// MARK: - SUWA-17 E2: the measuring ahead stops when it is no longer wanted
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// Down quickly from a slow server: the pages left behind (out of the preload range) stop loading, they do not
    /// keep the server's slots in front of the pages coming.
    @Test func pagesLeftBehindStopLoading() async throws {
        let opened = try await open(.remote(delay: 1.0), mangaKey: "dejadas", preload: 6)
        let loader = try #require(opened.loader)
        try await watch(opened, seconds: 1) { _ in }
        try await scroll(opened, seconds: 3, velocity: 3000) { _ in }
        let screen = opened.webtoon.collectionNode.bounds.height
        let behind = opened.pageRows.filter { (opened.frame($0)?.maxY ?? .infinity) < opened.top - 3 * screen }
        try #require(behind.count >= 3, "only \(behind.count) rows left behind")
        let names = behind.map { "/c1-\($0 - 1).jpg" }
        let stillLoading = loader.pending.filter { path in names.contains { path.hasSuffix($0) } }
        #expect(stillLoading.isEmpty, "\(stillLoading.count) pages left behind still loading: \(stillLoading.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted())")
        await opened.close()
    }

    /// Another chapter opened while the pages of the first one are being measured: those stop.
    @Test func changingChapterStopsTheMeasuringOfTheOldOne() async throws {
        let opened = try await open(.remote(delay: 1.0), mangaKey: "cambiocap", preload: 6)
        let loader = try #require(opened.loader)
        try await watch(opened, seconds: 0.5) { _ in }
        try #require(loader.pending.contains { $0.contains("/c1-") }, "nothing of chapter 1 loading")
        opened.webtoon.setChapter(AidokuRunner.Chapter(key: "c2", chapterNumber: 2), startPage: 1)
        try await watch(opened, seconds: 1) { _ in }
        let old = loader.pending.filter { $0.contains("/c1-") }
        #expect(old.isEmpty, "\(old.count) pages of chapter 1 still loading: \(old.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted())")
        await opened.close()
    }

    /// A measuring cancelled and a new one started at once: when the old one ends, the page still knows the new
    /// one is going (it does not start a second one, and can still cancel it).
    @Test func aCancelledMeasuringDoesNotForgetTheNextOne() async throws {
        let opened = try await open(.remote(delay: 1.0), mangaKey: "relevo", preload: 1)
        try await watch(opened, seconds: 0.5) { _ in }
        let row = opened.pageRows.upperBound - 1
        let node = try #require(opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: row, section: 0)) as? ReaderWebtoonPageNode)
        try #require(!opened.isMeasured(row))
        node.measureAhead()
        node.cancelMeasureAhead()
        node.measureAhead()
        try await Task.sleep(for: .milliseconds(400))
        #expect(node.isMeasuringAhead, "the page forgot its measuring")
        await opened.close()
    }
}

// MARK: - SUWA-17 E3: what a measuring changes, on the main thread
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    final class Threads: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func add(_ value: Bool) { lock.withLock { values.append(value) } }
        var all: [Bool] { lock.withLock { values } }
    }

    /// The page's height, its ratio and its measuring state are changed on the main thread (the layout is
    /// Texture's and the main thread's).
    @Test func measuringsAreAppliedOnTheMainThread() async throws {
        let threads = Threads()
        ReaderWebtoonPageNode.measurementApplied = { threads.add($0) }
        defer { ReaderWebtoonPageNode.measurementApplied = nil }
        let opened = try await open(.remote(delay: 0.3), mangaKey: "hilo", preload: 6)
        try await watch(opened, seconds: 4) { _ in }
        await opened.close()
        let all = threads.all
        try #require(!all.isEmpty, "no page measured ahead")
        #expect(all.allSatisfy { $0 }, "\(all.filter { !$0 }.count) of \(all.count) applied off the main thread")
    }
}

// MARK: - SUWA-17 E6: the pause after a memory warning
extension ImagePipelineSwappingTests.ReaderWebtoonPreloadTests {
    /// After a memory warning nothing is measured ahead for half a minute; after it, again.
    @Test func afterAMemoryWarningNothingIsMeasuredAheadForHalfAMinute() async throws {
        let opened = try await open(.remote(delay: 1.0), mangaKey: "pausa", preload: 6)
        let measuring: () -> [Int] = {
            opened.pageRows.filter { (opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: $0, section: 0)) as? ReaderWebtoonPageNode)?.isMeasuringAhead == true }
        }
        // the first pages in (until then the scroll view outside has no size yet: nothing to scroll)
        try await watch(opened, seconds: 2) { _ in }
        let opening = "y \(Int(opened.webtoon.scrollView.contentOffset.y)) contentSize \(Int(opened.webtoon.scrollView.contentSize.height)) layout \(Int(opened.layout.collectionViewContentSize.height))"
        try #require(!measuring().isEmpty, "nothing measuring ahead after opening")
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(measuring().isEmpty, "rows \(measuring()) still measuring after the warning")
        let sv = opened.webtoon.scrollView
        let before = "y \(Int(sv.contentOffset.y)) contentSize \(Int(sv.contentSize.height)) layout \(Int(opened.layout.collectionViewContentSize.height)) bounds \(Int(sv.bounds.height))"
        try await scroll(opened, seconds: 0.5, velocity: 900) { _ in }
        try await watch(opened, seconds: 0.3) { _ in }
        let after = "y \(Int(sv.contentOffset.y)) contentSize \(Int(sv.contentSize.height)) layout \(Int(opened.layout.collectionViewContentSize.height))"
        #expect(measuring().isEmpty, "rows \(measuring()) measuring during the pause")
        #expect(sv.contentOffset.y > 300, "did not move: opening \(opening); \(before) → \(after)")
        // half a minute later
        try #require(opened.webtoon.measureAheadPausedUntil != nil)
        opened.webtoon.measureAheadPausedUntil = Date()
        try await scroll(opened, seconds: 0.5, velocity: 900) { _ in }
        try await watch(opened, seconds: 0.3) { _ in }
        let state: () -> String = {
            guard let last = opened.lastVisibleRow else { return "?" }
            return ((last + 1)...(last + 7)).filter { opened.pageRows.contains($0) }.map { row in
                let node = opened.webtoon.collectionNode.nodeForItem(at: IndexPath(row: row, section: 0)) as? ReaderWebtoonPageNode
                return "\(row):\(opened.isMeasured(row) ? "M" : "-")\(node?.isMeasuringAhead == true ? "m" : "-")\(node?.image != nil ? "i" : "-")"
            }.joined(separator: " ")
        }
        #expect(!measuring().isEmpty || opened.measuredBelow >= 6, "nothing measured ahead after the pause: \(state()) paused \(String(describing: opened.webtoon.measureAheadPausedUntil))")
        await opened.close()
    }
}
