//
//  ReaderTransitionTests.swift
//  AidokuTests
//
//  SUWA-12 I2: with the app in front, passing the last page in one go to the transition (37 → 39)
//  completes, as before and as upstream; a jump from further back doesn't.
//

import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit

@testable import Aidoku

@MainActor
@Suite(.serialized) struct ReaderTransitionTests {
    @Test func pastTheLastPageInOneGoCompletes() {
        #expect(ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [36, 37], previousPage: 37, inForeground: true))
    }

    @Test func aJumpFromFurtherBackDoesNotComplete() {
        #expect(!ReaderCompletion.pageReportCompletes(pages: 39...39, totalPages: 38, seenPages: [17, 18], previousPage: 18, inForeground: true))
    }

    @Test func theReaderCompletesFrom37To39() async throws {
        let center = NotificationCenter()
        let (reader, chapterId) = makeTestReader(mangaKey: "transicion", center: center)
        await removeTestHistory(chapterId)
        defer { Task { await removeTestHistory(chapterId) } }
        reader.setCurrentPage(37, position: nil)
        reader.setCurrentPage(39, position: nil)
        try await Task.sleep(for: .seconds(1))
        #expect(await storedProgress(chapterId).completed == true)
    }
}
