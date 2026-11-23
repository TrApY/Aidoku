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

    /// A journal of its own. Incognito goes to `record` itself: turning on the app's setting would drop what the
    /// suites running meanwhile record or save.
    private func withJournal(incognito: Bool = false, _ body: (URL) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("completados-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try body(url)
    }

    @Test func everyCompletionSaysWhy() {
        withJournal { url in
            CompletionJournal.record(chapter, reason: "webtoon: final visto", detail: "abajo fuera", fileUrl: url, incognito: false)
            let lines = CompletionJournal.lines(fileUrl: url)
            #expect(lines.count == 1)
            #expect(lines.first?.hasSuffix("\tsuwayomi.x.1\t1021\t7035\twebtoon: final visto\tabajo fuera") == true)
        }
    }

    @Test func theJournalStaysShort() {
        withJournal { url in
            for index in 1...(CompletionJournal.maxLines + 1) {
                CompletionJournal.record(chapter, reason: "n\(index)", fileUrl: url, incognito: false)
            }
            let lines = CompletionJournal.lines(fileUrl: url)
            #expect(lines.count == CompletionJournal.keptLines)
            #expect(lines.last?.contains("\tn\(CompletionJournal.maxLines + 1)\t") == true)
        }
    }

    /// Checking incognito does not turn on the app's own setting: the other suites run at the same time in the same
    /// process, and anything they record or save meanwhile would be dropped as incognito (a migration test lost its
    /// journal line in a full pass).
    @Test func checkingIncognitoLeavesTheAppsSettingAlone() {
        let before = AppSettings.general.incognitoMode.get()
        withJournal(incognito: true) { _ in
            #expect(AppSettings.general.incognitoMode.get() == before, "the app's setting changed while checking incognito")
        }
    }

    @Test func incognitoWritesNothing() {
        withJournal(incognito: true) { url in
            CompletionJournal.record(chapter, reason: "lector", fileUrl: url, incognito: true)
            #expect(CompletionJournal.lines(fileUrl: url).isEmpty)
        }
    }
}

// MARK: - SUWA-17 G3a: the tests' journal is not the app's
extension CompletionJournalTests {
    /// Running the tests, the journal is a temporary file: what they record never goes into the app's own one.
    @Test func theTestsJournalIsATemporaryFile() throws {
        let real = FileManager.default.applicationSupportDirectory.appendingPathComponent("completados.log")
        let before = try? Data(contentsOf: real)
        #expect(CompletionJournal.defaultUrl.path.hasPrefix(FileManager.default.temporaryDirectory.path), "\(CompletionJournal.defaultUrl.path)")
        CompletionJournal.record(.init(sourceKey: "diariopruebas", mangaKey: "m", chapterKey: "c"), reason: "test")
        #expect((try? Data(contentsOf: real)) == before, "written in the app's journal")
    }
}

// MARK: - SUWA-17 G3b: many completions in a row keep the one of a chapter being read again
extension CompletionJournalTests {
    /// A chapter completed, then more completions than the journal keeps (marking many as read, a sync): its
    /// completion is still known, so it is still being read again.
    @Test func manyCompletionsAfterwardsKeepAChaptersCompletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muchos-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: CompletionJournal.latestUrl(for: url))
        }
        let chapter = ChapterIdentifier(sourceKey: "muchos", mangaKey: "m", chapterKey: "releido")
        let completedAt = Date().addingTimeInterval(-600)
        CompletionJournal.record(chapter, reason: "lector: test", date: completedAt, fileUrl: url)
        for index in 1...(CompletionJournal.maxLines + 1) {
            CompletionJournal.record(.init(sourceKey: "muchos", mangaKey: "m", chapterKey: "n\(index)"), reason: "sincronización test", fileUrl: url)
        }
        let completions = CompletionJournal.latestCompletions(fileUrl: url)
        #expect(RereadRule.isRereading(chapter: chapter, sessionStart: Date().addingTimeInterval(-60), completions: completions),
                "its completion was pushed out of the journal")
    }
}

// MARK: - SUWA-17 G3d: reading the journal on the main thread
extension CompletionJournalTests {
    /// What the reader and the manga page do on the main thread to decide a chapter: the completions of a full
    /// journal (300 lines) and a full file of latest completions (2000), read once and then kept in memory.
    @Test @MainActor func decidingAChapterOnTheMainThreadIsQuick() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lleno-\(UUID().uuidString).log")
        let latest = CompletionJournal.latestUrl(for: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: latest)
        }
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let journal = (1...CompletionJournal.maxLines).map {
            "\(date)\tlleno\tm\($0 % 20)\tc\($0)\tlector: página 38...38 de 38 (Optional<ReaderReader>)\tabajo 1/38, capítulo 0 de 2 con 40"
        }
        try (journal.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let latestLines = (1...CompletionJournal.maxLatest).map { "\(date)\tlleno\tm\($0 % 50)\tl\($0)\tlector: test" }
        try (latestLines.joined(separator: "\n") + "\n").write(to: latest, atomically: true, encoding: .utf8)
        let chapter = ChapterIdentifier(sourceKey: "lleno", mangaKey: "m7", chapterKey: "c7")
        let coldStart = ContinuousClock.now
        #expect(RereadRule.isRereading(chapter: chapter, sessionStart: Date(), completions: CompletionJournal.latestCompletions(fileUrl: url)))
        let cold = ContinuousClock.now - coldStart
        var times: [Duration] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            _ = RereadRule.isRereading(chapter: chapter, sessionStart: Date(), completions: CompletionJournal.latestCompletions(fileUrl: url))
            times.append(ContinuousClock.now - start)
        }
        times.sort()
        let report = "decidir un capítulo con el diario lleno: primera vez \(cold), después mediana \(times[times.count / 2]), máximo \(times.last!)\n"
        if let out = ProcessInfo.processInfo.environment["SUWA13_OUT"] {
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try report.write(to: URL(fileURLWithPath: out).appendingPathComponent("lectura-diario.txt"), atomically: true, encoding: .utf8)
        }
        print("SUWA17G3D " + report)
        #expect(times[times.count / 2] < .milliseconds(5))
    }
}
