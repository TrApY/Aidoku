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
        FileManager.default.applicationSupportDirectory.appendingPathComponent("completados.log")
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    static func record(_ chapter: ChapterIdentifier, reason: String, detail: String = "", date: Date = Date(), fileUrl: URL? = nil) {
        guard !AppSettings.general.incognitoMode.get() else { return }
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
        }
    }

    /// When the chapter was last marked completed on this device (not the readers' own «webtoon:» notes), from
    /// the journal's `lines` (SUWA-17 F2).
    static func lastCompletion(of chapter: ChapterIdentifier, lines: [String]) -> Date? {
        var last: Date?
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard
                fields.count >= 5,
                fields[1] == chapter.sourceKey, fields[2] == chapter.mangaKey, fields[3] == chapter.chapterKey,
                !fields[4].hasPrefix("webtoon:"),
                let date = lock.withLock({ formatter.date(from: String(fields[0])) })
            else { continue }
            if last.map({ date > $0 }) ?? true {
                last = date
            }
        }
        return last
    }

    static func lines(fileUrl: URL? = nil) -> [String] {
        guard let text = try? String(contentsOf: fileUrl ?? defaultUrl, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
