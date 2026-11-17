//
//  PageRatioStoreTests.swift
//  AidokuTests
//
//  SUWA-25 (ReadingAnchor, paso 6): the ratios of the pages already shown are kept in a file in Caches, so after
//  the app is opened again a page shown before is made with its height (not ancho×1,435 until its image comes).
//  Nothing in Core Data, CloudKit or UserDefaults.
//

import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Aidoku

@Suite struct PageRatioStoreTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ratios-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A ratio set and saved is there for a store opened later on the same file (the app opened again).
    @Test func aRatioSurvivesANewLaunch() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        let first = PageRatioMemory(fileURL: file, saveDelay: 3600)
        first.set(2.75, for: "fuente|https://example.invalid/1.jpg|ajustes")
        first.saveNow()
        let second = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(second["fuente|https://example.invalid/1.jpg|ajustes"] == 2.75)
    }

    /// Without saveNow, a change is written once the delay has passed.
    @Test func aChangeIsWrittenAfterTheDelay() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        let first = PageRatioMemory(fileURL: file, saveDelay: 0.2)
        first.set(1.5, for: "k")
        try await Task.sleep(for: .seconds(1.5))
        let second = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(second["k"] == 1.5)
    }

    /// Going to the background writes what is pending at once (the app may be killed there).
    @Test func goingToTheBackgroundWritesAtOnce() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        let center = NotificationCenter()
        let first = PageRatioMemory(fileURL: file, saveDelay: 3600, center: center)
        first.set(3.25, for: "k")
        center.post(name: Notification.Name("UIApplicationDidEnterBackgroundNotification"), object: nil)
        let second = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(second["k"] == 3.25)
    }

    /// It keeps at most `limit` pages, in memory and in the file: the oldest go first.
    @Test func theStoreKeepsAtMostItsLimitDroppingTheOldest() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        let first = PageRatioMemory(fileURL: file, limit: 2, saveDelay: 3600)
        first.set(1.1, for: "a")
        first.set(1.2, for: "b")
        first.set(1.3, for: "c")
        #expect(first["a"] == nil, "the oldest stays in memory")
        first.saveNow()
        let second = PageRatioMemory(fileURL: file, limit: 2, saveDelay: 3600)
        #expect(second["a"] == nil, "the oldest stays in the file")
        #expect(second["b"] == 1.2)
        #expect(second["c"] == 1.3)
    }

    /// A file that cannot be read is ignored: the store starts empty and writes a good one.
    @Test func aCorruptFileIsIgnored() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        try Data("esto no es un plist".utf8).write(to: file)
        let first = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(first["k"] == nil)
        first.set(2.0, for: "k")
        first.saveNow()
        let second = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(second["k"] == 2.0)
    }

    /// The shared store keeps its file in Caches (nothing in Core Data, CloudKit or UserDefaults).
    @Test func theSharedStoreLivesInCaches() throws {
        let url = try #require(PageRatioMemory.defaultFileURL, "the shared store has no file")
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        #expect(url.standardizedFileURL.path.hasPrefix(caches.standardizedFileURL.path))
    }

    /// A page from a server, shown in an earlier launch, is made with its height after the app is opened again
    /// (nothing in the image cache: before, it was made ancho×1,435 until its image came).
    @Test func aRemotePageShownBeforeIsMadeWithItsHeightAfterANewLaunch() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        let page = Aidoku.Page(sourceId: "lectoralturas", chapterId: "c1", index: 3,
                               imageURL: "https://example.invalid/\(UUID().uuidString)/3.jpg")
        let settings = ReaderWebtoonPageNode.ImageSettings(key: "false-false-false-0-1", cropsBorders: false)
        let key = try #require(ReaderWebtoonPageNode.ratioKey(of: page, settings: settings))
        let shown = PageRatioMemory(fileURL: file, saveDelay: 3600)
        shown.set(4.5, for: key)
        shown.saveNow()
        let reopened = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(ReaderWebtoonPageNode.knownRatio(of: page, source: nil, settings: settings, memory: reopened) == 4.5)
    }

    /// Cropping the borders: the header does not tell the size, so only an earlier showing does; after the app is
    /// opened again it still does.
    @Test func withCropBordersAPageShownBeforeIsMadeWithItsHeightAfterANewLaunch() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("PageRatios.plist")
        let page = Aidoku.Page(sourceId: "lectoralturas", chapterId: "c1", index: 4,
                               imageURL: "https://example.invalid/\(UUID().uuidString)/4.jpg")
        let settings = ReaderWebtoonPageNode.ImageSettings(key: "true-false-false-0-1", cropsBorders: true)
        let key = try #require(ReaderWebtoonPageNode.ratioKey(of: page, settings: settings))
        let shown = PageRatioMemory(fileURL: file, saveDelay: 3600)
        shown.set(1.25, for: key)
        shown.saveNow()
        let reopened = PageRatioMemory(fileURL: file, saveDelay: 3600)
        #expect(ReaderWebtoonPageNode.knownRatio(of: page, source: nil, settings: settings, memory: reopened) == 1.25)
    }

    /// Text pages have no key: nothing of them is kept (the text readers do not use this store). Born green: it
    /// protects what is already so.
    @Test func textPagesAreNotStored() {
        let page = Aidoku.Page(sourceId: "lectoralturas", chapterId: "c1", index: 0, text: "Érase una vez")
        let settings = ReaderWebtoonPageNode.ImageSettings(key: "false-false-false-0-1", cropsBorders: false)
        #expect(ReaderWebtoonPageNode.ratioKey(of: page, settings: settings) == nil)
    }
}
