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
    /// Text pages (a novel's chapter of several pages, which the webtoon reader shows: SUWA-19 revisión, hallazgo 3).
    private static func textPages(sourceKey: String, chapterKey: String) -> [Aidoku.Page] {
        (0..<pageCount).map { index in
            let text = (1...12).map { "Párrafo \($0) de la página \(index). " + String(repeating: "Texto de prueba. ", count: 20) }
                .joined(separator: "\n\n")
            return Aidoku.Page(sourceId: sourceKey, chapterId: chapterKey, index: index, text: text)
        }
    }

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
            let url = directory.appendingPathComponent("\(chapterKey)-\(index).png")
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
        /// The next chapter's ("c2"), when it was opened with one.
        var nextId: ChapterIdentifier?
        var nextDirectory: URL?

        func close() async {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: modeKey)
            try? FileManager.default.removeItem(at: directory)
            await removeTestHistory(chapterId)
            if let nextId {
                await removeTestHistory(nextId)
            }
            if let nextDirectory {
                try? FileManager.default.removeItem(at: nextDirectory)
            }
        }

        func frame(row: Int, section: Int = 0) throws -> CGRect {
            try #require(webtoon.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(row: row, section: section))?.frame)
        }
    }

    /// Opens chapter "c1" in the webtoon reader at the stored page `startPage`; `wait` seconds for the images.
    /// `next`: with chapter "c2" after it, its pages ready for the reader; `text`: text pages instead of images.
    private func open(
        mangaKey: String, startPage: Int, position: Double? = nil, wait: Double = 5, next: Bool = false, text: Bool = false
    ) async throws -> Opened {
        let chapter = AidokuRunner.Chapter(key: "c1", chapterNumber: 1)
        let second = AidokuRunner.Chapter(key: "c2", chapterNumber: 2)
        let manga = AidokuRunner.Manga(sourceKey: "lectorancla", key: mangaKey, title: "Webtoon", chapters: next ? [second, chapter] : nil)
        let chapterId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
        await removeTestHistory(chapterId)
        await DataRepositories.shared.history.savePage(PageSave(
            chapter: chapterId, page: startPage, totalPages: Self.pageCount, scrollPosition: position
        ))
        let modeKey = "Reader.readingMode.\(manga.identifier)"
        UserDefaults.standard.set("webtoon", forKey: modeKey)
        var (pages, directory) = try Self.pages(sourceKey: manga.sourceKey, chapterKey: chapter.key)
        if text {
            pages = Self.textPages(sourceKey: manga.sourceKey, chapterKey: chapter.key)
        }
        let nextId = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: second.key)
        if next {
            await removeTestHistory(nextId)
        }

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
        if next {
            // what the reader gets when it asks for the next chapter
            let nextPages = try Self.pages(sourceKey: manga.sourceKey, chapterKey: second.key)
            webtoon.viewModel.preloadedChapter = second
            webtoon.viewModel.preloadedPages = nextPages.pages
            return Opened(
                reader: reader, webtoon: webtoon, chapterId: chapterId, window: window, center: center, directory: directory, modeKey: modeKey,
                nextId: nextId, nextDirectory: nextPages.directory
            )
        }
        return Opened(
            reader: reader, webtoon: webtoon, chapterId: chapterId, window: window, center: center, directory: directory, modeKey: modeKey
        )
    }

    /// The user drags until the middle of the screen is at `fraction` of `row`, and lets go.
    private func userScrolls(_ opened: Opened, toRow row: Int, section: Int = 0, at fraction: CGFloat = 0.5) throws {
        let webtoon = opened.webtoon
        let frame = try opened.frame(row: row, section: section)
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

    // MARK: - SUWA-19 revisión (W6)

    /// From chapter 1 opened at page 36, the user goes down to its end: chapter 2 is put in below. Returns the row
    /// of chapter 2's page `page` in its section (its first row is its transition only when it has one).
    private func goDownIntoTheNextChapter(_ opened: Opened, page: Int) async throws -> Int {
        try userScrolls(opened, toRow: Self.pageCount)
        try await Task.sleep(for: .seconds(1))
        try userScrolls(opened, toRow: Self.pageCount + 1)
        for _ in 0..<40 where opened.webtoon.collectionNode.numberOfSections < 2 {
            try await Task.sleep(for: .milliseconds(250))
        }
        try #require(opened.webtoon.collectionNode.numberOfSections == 2, "chapter 2 was not put in below")
        try await Task.sleep(for: .seconds(2))
        let items = opened.webtoon.collectionNode.numberOfItems(inSection: 1)
        return items == Self.pageCount + 2 ? page : page - 1
    }

    /// Hallazgo 1: chapter 2, put in below by the infinite scroll (its first row is its first page), read at its page
    /// 3 at 43 %: its history keeps 3.4 (before, only chapters opened directly kept their fraction).
    @Test func aChapterPutInBelowSavesItsFraction() async throws {
        let opened = try await open(mangaKey: "fraccionabajo", startPage: 36, next: true)
        let row = try await goDownIntoTheNextChapter(opened, page: 3)
        try userScrolls(opened, toRow: row, section: 1, at: 0.43)
        try await Task.sleep(for: .seconds(1))
        try #require(opened.reader.chapter.key == "c2", "not in chapter 2")
        try #require(opened.reader.currentPage == 3, "at page \(opened.reader.currentPage)")
        try await Task.sleep(for: .seconds(7))
        let id = try #require(opened.nextId)
        let record = try #require(await DataRepositories.shared.history.record(of: id), "nothing saved of chapter 2")
        #expect(record.progress == 3)
        let position = try #require(record.scrollPosition, "no scroll position saved for chapter 2")
        #expect(abs(position - 3.4) < 0.001, "saved \(position)")
        await opened.close()
    }

    /// Hallazgo 2 (JoTa, 17-nov: a): moving inside the page the chapter opened at keeps where in it, but it is not
    /// reading: the read date stays (so does «Continuar»), also when leaving the reader.
    @Test func movingInsideTheOpeningPageSavesTheFractionWithoutCountingAsReading() async throws {
        let opened = try await open(mangaKey: "fraccionapertura", startPage: 5)
        let before = try #require(await DataRepositories.shared.history.record(of: opened.chapterId))
        try userScrolls(opened, toRow: 5, at: 0.4)
        try await Task.sleep(for: .seconds(7))
        opened.reader.viewWillDisappear(false)
        try await Task.sleep(for: .seconds(1))
        let after = try #require(await DataRepositories.shared.history.record(of: opened.chapterId))
        #expect(after.progress == 5)
        #expect(after.dateRead == before.dateRead, "read date \(String(describing: before.dateRead)) → \(String(describing: after.dateRead))")
        let position = try #require(after.scrollPosition, "the fraction was not saved")
        #expect(abs(position - 5.4) < 0.001, "saved \(position)")
        await opened.close()
    }

    /// Hallazgo 2: turning to another page after that is reading, as always: the read date changes. Born green: it
    /// keeps the fix of hallazgo 2 from also swallowing the page changes.
    @Test func turningThePageAfterMovingInsideTheOpeningOneCountsAsReading() async throws {
        let opened = try await open(mangaKey: "fraccionpasar", startPage: 5)
        let before = try #require(await DataRepositories.shared.history.record(of: opened.chapterId))
        try userScrolls(opened, toRow: 5, at: 0.4)
        try await Task.sleep(for: .seconds(1))
        try userScrolls(opened, toRow: 6, at: 0.2)
        try await Task.sleep(for: .seconds(7))
        let after = try #require(await DataRepositories.shared.history.record(of: opened.chapterId))
        #expect(after.progress == 6)
        #expect((after.dateRead ?? .distantPast) > (before.dateRead ?? .distantPast), "the read date did not change")
        #expect(abs((after.scrollPosition ?? 0) - 6.2) < 0.001, "saved \(String(describing: after.scrollPosition))")
        await opened.close()
    }

    /// Hallazgo 3: text pages shown in the webtoon reader (a chapter of several text pages) do not get a webtoon
    /// fraction: a text reader would read 7.4 as its own progress.
    @Test func textPagesInTheWebtoonDoNotSaveAFraction() async throws {
        let opened = try await open(mangaKey: "fracciontextowebtoon", startPage: 5, text: true)
        try #require(opened.reader.reader is ReaderWebtoonViewController, "not the webtoon reader")
        try userScrolls(opened, toRow: 7, at: 0.43)
        try await Task.sleep(for: .seconds(7))
        let record = try #require(await DataRepositories.shared.history.record(of: opened.chapterId))
        try #require(record.progress == 7, "saved page \(record.progress)")
        #expect(record.scrollPosition == nil, "saved \(String(describing: record.scrollPosition))")
        await opened.close()
    }

    /// Hallazgo 5: a double tap's zoom that ends with the middle of the screen in the next chapter changes the
    /// chapter then, not at the next scroll event (which may be a layout pass out of front).
    @Test func aDoubleTapZoomEndingInTheNextChapterChangesItAtOnce() async throws {
        let opened = try await open(mangaKey: "zoomcapitulo", startPage: 36, next: true)
        let row = try await goDownIntoTheNextChapter(opened, page: 2)
        try #require(opened.reader.chapter.key == "c1", "already in chapter 2")
        let webtoon = opened.webtoon
        // the zoom animation moves the content (no scroll events reach the reader while it zooms)
        webtoon.isZooming = true
        let frame = try opened.frame(row: row, section: 1)
        webtoon.scrollView.setContentOffset(CGPoint(x: 0, y: frame.midY - webtoon.collectionNode.bounds.height / 2), animated: false)
        webtoon.isZooming = false
        webtoon.zoomView.onZoomAnimationEnded?()
        #expect(webtoon.anchor?.chapterKey == "c2")
        #expect(opened.reader.chapter.key == "c2", "the chapter did not change with the zoom")
        await opened.close()
    }

    /// Hallazgo 8: a size transition stops a deceleration without UIKit telling it ended: after it, the content moved
    /// by something else is not the user moving (before, the user stayed «scrolling» and that moved the anchor).
    @Test func aSizeTransitionDuringADecelerationEndsTheUsersScroll() async throws {
        let opened = try await open(mangaKey: "giroinercia", startPage: 5)
        try userScrolls(opened, toRow: 7, at: 0.3)
        try await Task.sleep(for: .milliseconds(500))
        let webtoon = opened.webtoon
        webtoon.scrollViewWillBeginDragging(webtoon.scrollView)
        webtoon.scrollViewDidEndDragging(webtoon.scrollView, willDecelerate: true)
        let before = try #require(webtoon.anchor)
        let coordinator = SteppedTransitionCoordinator()
        webtoon.viewWillTransition(to: CGSize(width: 402, height: 874), with: coordinator)
        coordinator.runAnimations()
        opened.window.layoutIfNeeded()
        coordinator.complete()
        try await Task.sleep(for: .milliseconds(300))
        let scrollView = webtoon.scrollView
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y + 700), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(webtoon.anchor?.item == before.item && abs((webtoon.anchor?.fraction ?? 0) - before.fraction) < 0.001,
                "\(before) → \(String(describing: webtoon.anchor))")
        let distance = try distanceFromTheAnchor(opened)
        #expect(abs(distance) < 1, "the anchor's point is \(distance) pt from its place")
        await opened.close()
    }
}
}
