//
//  ReaderBackgroundSaveTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L5: going to the background, the reader saves the page inside a background task
//  (UIApplication.beginBackgroundTask, ReaderViewController.saveReadPositionNow). The page is stored before that
//  task ends, and the save does not get slower when it moves behind the repository (the times go to
//  $SUWA13_OUT/guardado-segundo-plano.txt).
//

import AidokuRunner
import Foundation
import Testing
import UIKit

@testable import Aidoku

@MainActor
@Suite(.serialized) struct ReaderBackgroundSaveTests {
    @Test func theBackgroundSaveStoresThePageBeforeTheTaskEnds() async throws {
        let center = NotificationCenter()
        let (reader, chapterId) = makeTestReader(mangaKey: "segundoplano", center: center)
        await removeTestHistory(chapterId)
        // loading the view starts the chapter load, which (no source in the test) ends empty a moment later and
        // leaves 0 pages: let it, then give the reader its 38 pages again (the save reads the total)
        reader.loadViewIfNeeded()
        try await Task.sleep(for: .seconds(2))
        reader.setPages((0..<38).map {
            Page(sourceId: chapterId.sourceKey, chapterId: chapterId.chapterKey, index: $0, imageURL: "https://example.invalid/\($0).jpg")
        })
        var times: [Duration] = []
        for page in [7, 12, 30, 31, 2] {
            reader.setCurrentPage(page, position: nil)
            let start = ContinuousClock.now
            let task = try #require(reader.saveReadPositionNow(), "page \(page): nothing to save")
            await task.value
            times.append(ContinuousClock.now - start)
            // stored when the task (and so the background task) ends
            let stored = await storedProgress(chapterId)
            #expect(stored.progress == page, "page \(page): reader at \(reader.currentPage), stored \(String(describing: stored))")
        }
        // a second notice (deactivating, then going to the background) finds the page saved
        #expect(reader.saveReadPositionNow() == nil)
        await removeTestHistory(chapterId)
        let sorted = times.sorted()
        // the times, outside the repo (SUWA13_OUT), to compare before and after
        if let out = ProcessInfo.processInfo.environment["SUWA13_OUT"] {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try "guardado en segundo plano: mediana \(sorted[sorted.count / 2]), máximo \(sorted.last!)\n"
                .write(to: URL(fileURLWithPath: out).appendingPathComponent("guardado-segundo-plano.txt"), atomically: true, encoding: .utf8)
        }
        // the background time is at least ~5 s; the save takes a small part of it
        #expect(sorted.last! < .seconds(1))
    }
}
