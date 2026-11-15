//
//  MigrationHistory.swift
//  Aidoku
//
//  How the reading history of a migrated manga is carried to the chapters of the new one.
//

import AidokuRunner
import Foundation

enum MigrationHistory {
    /// A history entry of the old manga.
    struct Entry: Equatable, Sendable {
        var chapter: Float?
        var volume: Float?
        var completed: Bool
        var progress: Int = 0
        var total: Int = 0
        var dateRead: Date?
        var scrollPosition: Double?
    }

    /// A new chapter to mark as read, with the date it gets.
    struct Completed: Equatable, Sendable {
        let chapterKey: String
        let date: Date
    }

    /// A new chapter that keeps the old one's unfinished progress.
    struct InProgress: Equatable, Sendable {
        let chapterKey: String
        let progress: Int
        let total: Int
        let date: Date?
        let scrollPosition: Double?
    }

    struct Plan: Equatable, Sendable {
        var completed: [Completed] = []
        var inProgress: [InProgress] = []

        /// The highest chapter (or volume) read, for the trackers.
        var highestRead: Float?
    }

    /// - Read: only COMPLETED chapters count (highest chapter number; without numbers, highest volume).
    ///   The new chapters up to it are marked, by chapter number, or by volume if none matches.
    /// - Each marked chapter keeps the reading date of the old one with the same number; one without a
    ///   pair gets the most recent reading date of the old manga (never «now» if there is history).
    /// - An unfinished chapter (not completed, with progress) goes to the new chapter with the same number
    ///   (and volume if both have it) that isn't marked, keeping page, total, scroll position and date.
    static func plan(old: [Entry], newChapters: [AidokuRunner.Chapter], now: Date = Date()) -> Plan {
        let done = old.filter(\.completed)
        var maxRead = done.compactMap(\.chapter).max()
        if maxRead == nil || maxRead == -1 {
            // in case of no chapter numbers, the highest volume read
            maxRead = done.compactMap(\.volume).max()
        }
        let latest = old.compactMap(\.dateRead).max() ?? now
        var plan = Plan(highestRead: maxRead)

        var marked = Set<String>()
        if let maxRead {
            var byVolume = false
            var toMark = newChapters.filter { $0.chapterNumber ?? .greatestFiniteMagnitude <= maxRead }
            if toMark.isEmpty {
                // the source we're migrating to may use volumes
                toMark = newChapters.filter { $0.volumeNumber ?? .greatestFiniteMagnitude <= maxRead }
                byVolume = true
            }
            for chapter in toMark {
                let pair = byVolume
                    ? (done.first { same($0.volume, chapter.volumeNumber) } ?? old.first { same($0.volume, chapter.volumeNumber) })
                    : (pair(for: chapter, in: done) ?? pair(for: chapter, in: old))
                plan.completed.append(.init(chapterKey: chapter.key, date: pair?.dateRead ?? latest))
                marked.insert(chapter.key)
            }
        }

        var carried: [String: InProgress] = [:]
        for entry in old where !entry.completed && entry.progress > 0 {
            guard let number = entry.chapter else { continue }
            let target = newChapters.first { chapter in
                !marked.contains(chapter.key)
                    && same(chapter.chapterNumber, number)
                    && (entry.volume == nil || chapter.volumeNumber == nil || same(entry.volume, chapter.volumeNumber))
            }
            guard let target else { continue }
            if let kept = carried[target.key], (kept.date ?? .distantPast) >= (entry.dateRead ?? .distantPast) {
                continue // two old chapters with that number: the latest read
            }
            carried[target.key] = .init(
                chapterKey: target.key,
                progress: entry.progress,
                total: entry.total,
                date: entry.dateRead,
                scrollPosition: entry.scrollPosition
            )
        }
        plan.inProgress = newChapters.compactMap { carried[$0.key] }
        return plan
    }

    /// The old entry with the chapter's number, the one with its volume first.
    private static func pair(for chapter: AidokuRunner.Chapter, in entries: [Entry]) -> Entry? {
        let sameNumber = entries.filter { same($0.chapter, chapter.chapterNumber) }
        return sameNumber.first { same($0.volume, chapter.volumeNumber) } ?? sameNumber.first
    }

    private static func same(_ lhs: Float?, _ rhs: Float?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) < 0.0001
    }
}
