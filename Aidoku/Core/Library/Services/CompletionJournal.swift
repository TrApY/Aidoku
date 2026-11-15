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
         // pendiente[B#3]
    }

    static func lines(fileUrl: URL? = nil) -> [String] {
        guard let text = try? String(contentsOf: fileUrl ?? defaultUrl, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}
