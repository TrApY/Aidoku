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

    /// Pending: the old rule (every history entry counts as read, marked now).
    static func plan(old: [Entry], newChapters: [AidokuRunner.Chapter], now: Date = Date()) -> Plan {
        var maxRead = old.compactMap(\.chapter).max()
        if maxRead == nil || maxRead == -1 {
            maxRead = old.compactMap(\.volume).max()
        }
        guard let maxRead else { return .init() }
        var toMark = newChapters.filter { $0.chapterNumber ?? .greatestFiniteMagnitude <= maxRead }
        if toMark.isEmpty {
            toMark = newChapters.filter { $0.volumeNumber ?? .greatestFiniteMagnitude <= maxRead }
        }
        return .init(completed: toMark.map { .init(chapterKey: $0.key, date: now) }, highestRead: maxRead)
    }
}
