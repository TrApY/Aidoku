//
//  CompletionJournal.swift
//  Aidoku
//
//  SUWA-12 F: a short journal on the device of every chapter marked completed and why (reader and how it
//  saw the end, sync from a tracker, migration, «marcar como leído»), so a chapter marked read too early
//  can be traced. Kept in Application Support (not synced), the last lines only; nothing in incognito.
//

import Foundation

enum CompletionJournal {
    static let maxLines = 300
    static let keptLines = 200

    static var defaultUrl: URL {
        testsUrl ?? FileManager.default.applicationSupportDirectory.appendingPathComponent("completados.log")
    }

    /// Hosting the tests: a journal of their own in the temporary directory (new each run), so they never write in
    /// the app's real one (SUWA-17 G3a).
    private static let testsUrl: URL? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("completados-pruebas.log")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: latestUrl(for: url))
        return url
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// `incognito`: nil, the app's setting (tests pass it, so they never change the setting other tests read).
    static func record(
        _ chapter: ChapterIdentifier, reason: String, detail: String = "", date: Date = Date(), fileUrl: URL? = nil,
        incognito: Bool? = nil
    ) {
        guard !(incognito ?? AppSettings.general.incognitoMode.get()) else { return }
        let url = fileUrl ?? defaultUrl
        let line = [formatter.string(from: date), chapter.sourceKey, chapter.mangaKey, chapter.chapterKey, reason, detail]
            .joined(separator: "\t")
            .replacingOccurrences(of: "\n", with: " ")
        lock.withLock {
            var all = lines(fileUrl: url)
            all.append(line)
            if all.count > maxLines {
                all = Array(all.suffix(keptLines))
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (all.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            // the latest completion of each chapter, apart (not the readers' own «webtoon:» notes; SUWA-17 G3b)
            if !reason.hasPrefix("webtoon:") {
                let latestFile = latestUrl(for: url)
                let entryKey = key(chapter)
                let dateText = formatter.string(from: date)
                var latest = lines(fileUrl: latestFile).filter {
                    $0.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).dropFirst().prefix(3).joined(separator: "\t") != entryKey
                }
                latest.append([dateText, entryKey, reason].joined(separator: "\t").replacingOccurrences(of: "\n", with: " "))
                if latest.count > maxLatest {
                    latest = Array(latest.suffix(maxLatest))
                }
                try? (latest.joined(separator: "\n") + "\n").write(to: latestFile, atomically: true, encoding: .utf8)
                completionsByFile[url]?.dates[entryKey, default: []].append(dateText)
            }
        }
    }

    /// Latest completion of each chapter kept apart, at most (SUWA-17 G3b).
    static let maxLatest = 2000

    /// The file of the latest completion of each chapter, next to the journal (SUWA-17 G3b).
    static func latestUrl(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-ultimos.log")
    }

    /// The key of a chapter in `Completions`.
    static func key(_ chapter: ChapterIdentifier) -> String {
        [chapter.sourceKey, chapter.mangaKey, chapter.chapterKey].joined(separator: "\t")
    }

    /// The completions recorded on this device of each chapter, not the readers' own «webtoon:» notes: their dates
    /// as written, read only for the chapters asked about (SUWA-17 F2, G3b, G3d).
    struct Completions: Sendable {
        fileprivate(set) var dates: [String: [String]] = [:]

        func last(of chapter: ChapterIdentifier) -> Date? {
            CompletionJournal.lastDate(dates[CompletionJournal.key(chapter)] ?? [])
        }

        fileprivate mutating func add(_ lines: [String]) {
            for line in lines {
                let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
                guard fields.count >= 5, !fields[4].hasPrefix("webtoon:") else { continue }
                dates[fields[1...3].joined(separator: "\t"), default: []].append(String(fields[0]))
            }
        }
    }

    fileprivate static func lastDate(_ dates: [String]) -> Date? {
        lock.withLock { dates.compactMap { formatter.date(from: $0) }.max() }
    }

    /// The completions of each chapter recorded on this device: the latest one of each chapter, kept apart (the
    /// journal keeps its last lines only: marking many as read or a sync would push out the completion of a chapter
    /// being read again), and the journal; read once and then in memory, kept up to date by `record` (the reader and
    /// the manga page decide on the main thread; SUWA-17 G3b, G3d). `warmUp` reads them off the main thread.
    static func latestCompletions(fileUrl: URL? = nil) -> Completions {
        let url = fileUrl ?? defaultUrl
        return lock.withLock {
            if let cached = completionsByFile[url] {
                return cached
            }
            var completions = Completions()
            completions.add(lines(fileUrl: latestUrl(for: url)) + lines(fileUrl: url))
            completionsByFile[url] = completions
            return completions
        }
    }

    /// Reads the completions, so the main thread finds them read (at launch).
    static func warmUp() {
        Task.detached(priority: .utility) {
            _ = latestCompletions()
        }
    }

    /// `latestCompletions` of each journal file, once read.
    nonisolated(unsafe) private static var completionsByFile: [URL: Completions] = [:]

    static func lines(fileUrl: URL? = nil) -> [String] {
        guard let text = try? String(contentsOf: fileUrl ?? defaultUrl, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
