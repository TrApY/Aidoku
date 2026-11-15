//
//  CompletionJournalTests.swift
//  AidokuTests
//
//  SUWA-12 F: every chapter marked completed leaves a line saying why, on the device.
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct CompletionJournalTests {
    private let chapter = ChapterIdentifier(sourceKey: "suwayomi.x.1", mangaKey: "1021", chapterKey: "7035")

    private func withJournal(incognito: Bool = false, _ body: (URL) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("completados-\(UUID().uuidString).log")
        let saved = AppSettings.general.incognitoMode.get()
        AppSettings.general.incognitoMode.set(incognito)
        defer {
            AppSettings.general.incognitoMode.set(saved)
            try? FileManager.default.removeItem(at: url)
        }
        try body(url)
    }

    @Test func everyCompletionSaysWhy() {
        withJournal { url in
            CompletionJournal.record(chapter, reason: "webtoon: final visto", detail: "abajo fuera", fileUrl: url)
            let lines = CompletionJournal.lines(fileUrl: url)
            #expect(lines.count == 1)
            #expect(lines.first?.hasSuffix("\tsuwayomi.x.1\t1021\t7035\twebtoon: final visto\tabajo fuera") == true)
        }
    }

    @Test func theJournalStaysShort() {
        withJournal { url in
            for index in 1...(CompletionJournal.maxLines + 1) {
                CompletionJournal.record(chapter, reason: "n\(index)", fileUrl: url)
            }
            let lines = CompletionJournal.lines(fileUrl: url)
            #expect(lines.count == CompletionJournal.keptLines)
            #expect(lines.last?.contains("\tn\(CompletionJournal.maxLines + 1)\t") == true)
        }
    }

    @Test func incognitoWritesNothing() {
        withJournal(incognito: true) { url in
            CompletionJournal.record(chapter, reason: "lector", fileUrl: url)
            #expect(CompletionJournal.lines(fileUrl: url).isEmpty)
        }
    }
}
