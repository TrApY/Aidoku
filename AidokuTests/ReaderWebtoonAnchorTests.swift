//
//  ReaderWebtoonAnchorTests.swift
//  AidokuTests
//
//  SUWA-19 (ReadingAnchor): where the user is reading is a logical anchor (chapter, item, where in it) that only
//  the user moves; the page the reader reports is the anchor's. Through the real ReaderViewController and webtoon
//  reader, with real images taller than the provisional height.
//

import AidokuRunner
import AsyncDisplayKit
import Foundation
import Testing
import UIKit

@testable import Aidoku

extension ImagePipelineSwappingTests {
@MainActor
@Suite(.serialized) struct ReaderWebtoonAnchorTests {
    private static let pageCount = 38

    /// Pages as image files of 300×900 and 300×860 (about 1200 pt high on screen; the provisional one is ~577).
    private static func pages(sourceKey: String, chapterKey: String) throws -> (pages: [Aidoku.Page], directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ancla-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var pages: [Aidoku.Page] = []
        for index in 0..<pageCount {
            let size = CGSize(width: 300, height: index % 2 == 0 ? 900 : 860)
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor(hue: CGFloat(index) / CGFloat(pageCount), saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let url = directory.appendingPathComponent("\(index).png")
            try data.write(to: url)
            pages.append(Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, imageURL: url.absoluteString))
        }
        return (pages, directory)
    }

    @MainActor
    struct Opened {
        let reader: ReaderViewController
        let webtoon: ReaderWebtoonViewController
        let chapterId: ChapterIdentifier
        let window: UIWindow
        let center: NotificationCenter
        let directory: URL
        let modeKey: String

        func close() async {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
            await removeTestHistory(chapterId)
        }

        func frame(row: Int, section: Int = 0) throws -> CGRect {
            try #require(webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: section))?.frame)
        }
    }

    /// Opens chapter "c1" in the webtoon reader at the stored page `startPage`; `wait` seconds for the images.
    private func open(mangaKey: String, startPage: Int, position: Double? = nil, wait: Double = 5) async throws -> Opened {
        let manga = AidokuRunner.Manga(sourceKey: "lectorancla", key: mangaKey, title: "Webtoon")
        let chapter = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let chapterId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        await removeTestHistory(chapterId)
        await DataRepositories.shared.history.savePage(PageSave(
            chapter: chapterId, page: startPage, totalPages: Self.pageCount, scrollPosition: position
        ))
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        let (pages, directory) = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key)

        let reader = ReaderViewController(source: nil, manga: manga, chapter: chapter)
        let center = NotificationCenter()
        reader.appActivity = ReaderAppActivity(center: center, active: true)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = reader
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let webtoon = try #require(reader.reader as? ReaderWebtoonViewController, "not the webtoon reader")
        reader.presentedViewController?.dismiss(animated: false)
        webtoon.viewModel.preloadedChapter = chapter
        webtoon.viewModel.preloadedPages = pages
        reader.loadCurrentChapter()
        try await Task.sleep(for: .seconds(wait))
        return Opened(
            reader: reader, webtoon: webtoon, chapterId: chapterId, window: window, center: center, directory: directory, modeKey: modeKey
        )
    }

    /// The user drags until the middle of the screen is at `fraction` of `row`, and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int, at fraction: CGFloat = 0.5) throws {
        let webtoon = opened.webtoon
        let frame = try opened.frame(row: row)
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        let y = frame.minY + frame.height * fraction - webtoon.collectionNode.bounds.height / 2
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: false)
    }

    // MARK: - Paso 2: the reader keeps the anchor, only the user moves it, the page comes from it

    /// D4: the chapter opens with the top of the stored page at the top of the screen.
    @Test func openingSetsTheAnchorAtTheTopOfTheStartPage() async throws {
        let opened = try await open(mangaKey: "anclaabrir", startPage: 5)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after opening")
        #expect(anchor.chapterKey == "c1")
        #expect(anchor.item == 5)
        #expect(anchor.fraction == 0)
        #expect(anchor.screenFraction == 0)
        await opened.close()
    }

    /// The user drags: the anchor is the item in the middle of the screen and where in it.
    @Test func aDragChangesTheAnchorToTheMiddleOfTheScreen() async throws {
        let opened = try await open(mangaKey: "anclaarrastre", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.3)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after a drag")
        #expect(anchor.chapterKey == "c1")
        #expect(anchor.item == 7)
        #expect(abs(anchor.fraction - 0.3) < 0.01, "fraction \(anchor.fraction)")
        #expect(anchor.screenFraction == 0.5)
        #expect(anchor.measured)
        await opened.close()
    }

    /// I1: the content moving without the user (a layout pass, UIKit) does not change the anchor.
    @Test func aLayoutMoveDoesNotChangeTheAnchor() async throws {
        let opened = try await open(mangaKey: "anclalayout", startPage: 5)
        try userScrolls(opened, toRow: 6)
        try await Task.sleep(for: .milliseconds(500))
        let before = try #require(opened.webtoon.anchor, "no anchor after a drag")
        let scrollView = opened.webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y + 700), animated: false)
        try await Task.sleep(for: .milliseconds(500))
        #expect(opened.webtoon.anchor == before)
        await opened.close()
    }

    /// I3: the page reported is the anchor's: the content moving to page 8 without the user reports nothing.
    @Test func theReportedPageIsTheAnchorsPage() async throws {
        let opened = try await open(mangaKey: "anclapagina", startPage: 5)
        try userScrolls(opened, toRow: 6)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.currentPage == 6, "the drag did not report page 6: \(opened.reader.currentPage)")
        let target = try opened.frame(row: 8)
        let scrollView = opened.webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: target.midY - opened.webtoon.collectionNode.bounds.height / 2), animated: false)
        try await Task.sleep(for: .seconds(1))
        #expect(opened.reader.currentPage == 6)
        await opened.close()
    }

    // MARK: - Paso 3: the layout puts the screen back on the anchor at every pass

    /// Where the anchor's point is on the screen now, against where it should be (0 when it is in its place).
    private func distanceFromTheAnchor(_ opened: Opened) throws -> CGFloat {
        let webtoon = opened.webtoon
        let anchor = try #require(webtoon.anchor, "no anchor")
        let frame = try opened.frame(row: anchor.item)
        let point = frame.minY + frame.height * anchor.fraction - webtoon.collectionNode.contentOffset.y
        return point - anchor.screenFraction * webtoon.collectionNode.bounds.height
    }

    /// I2: the content moved without the user (UIKit, the zoom's scroll view): the next layout pass puts the
    /// screen back on the anchor, and both scroll views agree (I9).
    @Test func aMoveThatIsNotTheUsersIsUndoneAtTheNextLayout() async throws {
        let opened = try await open(mangaKey: "anclasiguiente", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.3)
        try await Task.sleep(for: .milliseconds(500))
        let before = try #require(opened.webtoon.anchor)
        let scrollView = opened.webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y + 700), animated: false)
        opened.webtoon.collectionNode.collectionViewLayout.invalidateLayout()
        opened.webtoon.collectionNode.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(opened.webtoon.anchor == before)
        let distance = try distanceFromTheAnchor(opened)
        #expect(abs(distance) < 1, "the anchor's point is \(distance) pt from its place")
        #expect(abs(scrollView.contentOffset.y - opened.webtoon.collectionNode.contentOffset.y) < 0.5)
        await opened.close()
    }

    /// I8: a memory warning lets go of the images but not of the heights: the anchor and the screen stay. Born
    /// green: it protects what the reader already does.
    @Test func releasingTheImagesKeepsTheAnchor() async throws {
        let opened = try await open(mangaKey: "anclamemoria", startPage: 5)
        try userScrolls(opened, toRow: 9, at: 0.6)
        try await Task.sleep(for: .milliseconds(500))
        let before = try #require(opened.webtoon.anchor)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await Task.sleep(for: .seconds(1))
        opened.webtoon.collectionNode.collectionViewLayout.invalidateLayout()
        opened.webtoon.collectionNode.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(opened.webtoon.anchor == before)
        let distance = try distanceFromTheAnchor(opened)
        #expect(abs(distance) < 1, "the anchor's point is \(distance) pt from its place")
        await opened.close()
    }

    // MARK: - Paso 4: the width, a rotation and coming back to the front, from the anchor

    /// D5: the content moved by something that is not the user (UIKit scaling the offset after a width change, the
    /// zoom's scroll view putting back an old offset) goes back on the anchor at once, without waiting for a layout.
    @Test func aMoveThatIsNotTheUsersIsUndoneAtOnce() async throws {
        let opened = try await open(mangaKey: "anclaenseguida", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.3)
        try await Task.sleep(for: .milliseconds(500))
        let before = try #require(opened.webtoon.anchor)
        let scrollView = opened.webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y + 700), animated: false)
        #expect(opened.webtoon.anchor == before)
        let distance = try distanceFromTheAnchor(opened)
        #expect(abs(distance) < 1, "the anchor's point is \(distance) pt from its place")
        #expect(abs(scrollView.contentOffset.y - opened.webtoon.collectionNode.contentOffset.y) < 0.5)
        await opened.close()
    }

    /// I7: out of front, the content moving (iPadOS, a drag that is not taken) does not move the anchor; back in
    /// front, the screen is on it and the page is the anchor's.
    @Test func backInFrontTheScreenIsOnTheAnchor() async throws {
        let opened = try await open(mangaKey: "anclaprimerplano", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.3)
        try await Task.sleep(for: .seconds(1))
        let before = try #require(opened.webtoon.anchor)
        opened.center.post(name: UIApplication.willResignActiveNotification, object: nil)
        try userScrolls(opened, toRow: 12)
        try await Task.sleep(for: .milliseconds(300))
        opened.center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(opened.webtoon.anchor == before)
        let distance = try distanceFromTheAnchor(opened)
        #expect(abs(distance) < 1, "the anchor's point is \(distance) pt from its place")
        #expect(opened.reader.currentPage == 7)
        await opened.close()
    }

    // MARK: - Paso 7: the fraction in History.scrollPosition (D12/D13)

    /// The user reads page 7 at 43 %: the history keeps page 7 and 7.4 (the page plus its fraction, rounded down to
    /// a tenth).
    @Test func theWebtoonSavesThePagePlusItsFractionRounded() async throws {
        let opened = try await open(mangaKey: "fraccionguardar", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.43)
        try await Task.sleep(for: .seconds(7))
        let record = try #require(await DataRepositories.shared.history.record(of: opened.chapterId), "nothing saved")
        #expect(record.progress == 7)
        let position = try #require(record.scrollPosition, "no scroll position saved")
        #expect(abs(position - 7.4) < 0.001, "saved \(position)")
        await opened.close()
    }

    /// Page 7 saved at 60 %: the chapter opens with that point of page 7 in the middle of the screen.
    @Test func reopeningPutsTheSavedFractionInTheMiddle() async throws {
        let opened = try await open(mangaKey: "fraccionabrir", startPage: 7, position: 7.6)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after opening")
        #expect(anchor.item == 7)
        #expect(abs(anchor.fraction - 0.6) < 0.001, "fraction \(anchor.fraction)")
        #expect(anchor.screenFraction == 0.5)
        let distance = try distanceFromTheAnchor(opened)
        #expect(abs(distance) < 1, "the anchor's point is \(distance) pt from its place")
        #expect(opened.reader.currentPage == 7)
        await opened.close()
    }

    /// A position saved for another page (an old version, another device that saved a page without one): the
    /// chapter opens at the top of the stored page.
    @Test func aFractionSavedForAnotherPageIsIgnored() async throws {
        let opened = try await open(mangaKey: "fraccionotra", startPage: 7, position: 5.6)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after opening")
        #expect(anchor.item == 7)
        #expect(anchor.fraction == 0)
        #expect(anchor.screenFraction == 0)
        await opened.close()
    }

    /// A text reader's position (0 to 1 into the chapter) is not a webtoon fraction: the top of the stored page.
    @Test func theTextReadersPositionIsNotReadAsAFraction() async throws {
        let opened = try await open(mangaKey: "fracciontexto", startPage: 7, position: 0.6)
        let anchor = try #require(opened.webtoon.anchor, "no anchor after opening")
        #expect(anchor.item == 7)
        #expect(anchor.fraction == 0)
        #expect(anchor.screenFraction == 0)
        await opened.close()
    }
}
}
