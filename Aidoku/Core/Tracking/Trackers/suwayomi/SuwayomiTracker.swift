//
//  SuwayomiTracker.swift
//  Aidoku
//
//  Created by skitty on 7/8/26.
//

import AidokuRunner
import Foundation

final class SuwayomiTracker: EnhancedTracker, PageTracker {
    let id = "suwayomi"
    let name = NSLocalizedString("SUWAYOMI")
    let icon = PlatformImage(named: "suwayomi")
    let isLoggedIn = true

    let api: SuwayomiApi
    /// Manga already marked in the server library during this session (sourceKey|id).
    let markedInLibrary = SuwayomiMarkedSet()

    init(api: SuwayomiApi = .init()) {
        self.api = api
    }
    private let idSeparator: Character = "|"

    func getTrackerInfo() -> TrackerInfo {
        .init(supportedStatuses: [], scoreType: .tenPoint, scoreOptions: [])
    }

    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? {
        let (sourceKey, seriesId) = try getIdParts(from: trackId)

        // called when the manga is added to the Aidoku library: keep it in the server library too
        // (manga opened from a server source are not in it yet)
        await addToServerLibrary(sourceKey: sourceKey, seriesId: seriesId)

        guard let highestChapterRead else { return nil }

        let state = try? await api.getState(sourceKey: sourceKey, seriesId: seriesId)
        if state?.lastReadChapter == nil || highestChapterRead > state?.lastReadChapter ?? 0 {
            try await api.update(
                sourceKey: sourceKey,
                seriesId: seriesId,
                update: .init(lastReadChapter: highestChapterRead)
            )
        }

        return nil
    }

    func update(trackId: String, update: TrackUpdate) async throws {
        let (sourceKey, seriesId) = try getIdParts(from: trackId)
        // register isn't called again for manga that kept their track item when re-added to the library
        await addToServerLibrary(sourceKey: sourceKey, seriesId: seriesId)
        try await api.update(
            sourceKey: sourceKey,
            seriesId: seriesId,
            update: update
        )
    }

    func getState(trackId: String) async throws -> TrackState {
        let (sourceKey, seriesId) = try getIdParts(from: trackId)
        guard let state = try await api.getState(sourceKey: sourceKey, seriesId: seriesId) else {
            throw SuwayomiTrackerError.getStateFailed
        }
        return state
    }

    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] {
        let state = try await api.getState(sourceKey: manga.sourceKey, seriesId: manga.key)
        if state != nil {
            return [.init(id: "\(manga.sourceKey)\(idSeparator)\(manga.key)", tracked: true)]
        } else {
            return []
        }
    }

    func getUrl(trackId: String) async -> URL? {
        nil
    }

    func canRegister(mangaId: MangaIdentifier) -> Bool {
        mangaId.sourceKey.hasPrefix(SuwayomiSourceRunner.sourceKeyPrefix)
            && !UserDefaults.standard.bool(forKey: "\(mangaId.sourceKey).disableTracking")
    }

    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws {
        let (sourceKey, seriesId) = try getIdParts(from: trackId)
        guard
            let seriesId = Int(seriesId),
            let chapterId = Int(chapterId.chapterKey)
        else {
            throw SuwayomiTrackerError.invalidId
        }
        try await api.updateReadProgress(
            sourceKey: sourceKey,
            seriesId: seriesId,
            chapterId: chapterId,
            progress: progress
        )
    }

    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress] {
        let (sourceKey, seriesId) = try getIdParts(from: trackId)
        return try await api.getSeriesReadProgress(sourceKey: sourceKey, seriesId: seriesId)
    }

    /// Forgets every manga tracked with the servers (as removing a server source does), instead of
    /// crashing: there's no account to log out of, the server login lives in the source settings.
    func logout() async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            for item in CoreDataManager.shared.getTracks(trackerId: self.id, context: context) {
                context.delete(item)
            }
            do {
                try context.save()
            } catch {
                LogManager.logger.error("Error removing suwayomi track items: \(error)")
            }
        }
        markedInLibrary.removeAll(withPrefix: "")
    }

    func removeTrackItems(sourceKey: String) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            let request = TrackObject.fetchRequest()
            request.predicate = NSPredicate(
                format: "trackerId == %@",
                self.id
            )
            do {
                let items = try? context.fetch(request)
                guard let items else { return }
                for item in items {
                    guard let id = item.id else { continue }
                    let (itemSourceKey, _) = try self.getIdParts(from: id)
                    if itemSourceKey == sourceKey {
                        context.delete(item)
                    }
                }
                try context.save()
            } catch {
                LogManager.logger.error("Error removing suwayomi track items: \(error)")
            }
        }
    }
}

extension SuwayomiTracker {
    /// Idempotent and best effort: a failure never breaks tracking. Only once per manga and session
    /// (update runs on every reading progress); a failed attempt is retried next time.
    private func addToServerLibrary(sourceKey: String, seriesId: String) async {
        let markKey = "\(sourceKey)\(idSeparator)\(seriesId)"
        guard !markedInLibrary.contains(markKey) else { return }
        do {
            try await api.addToLibrary(sourceKey: sourceKey, seriesId: seriesId)
            markedInLibrary.insert(markKey)
        } catch {
            LogManager.logger.error("Unable to add suwayomi manga \(seriesId) to the server library: \(error)")
        }
    }

    private func getIdParts(from id: String) throws -> (sourceKey: String, seriesId: String) {
        let split = id.split(separator: idSeparator, maxSplits: 2).map(String.init)
        guard split.count == 2 else { throw SuwayomiTrackerError.invalidId }
        return (sourceKey: split[0], seriesId: split[1])
    }
}

/// Thread-safe set of strings.
final class SuwayomiMarkedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()

    func contains(_ value: String) -> Bool {
        lock.withLock { values.contains(value) }
    }

    func insert(_ value: String) {
        lock.withLock { _ = values.insert(value) }
    }

    func remove(_ value: String) {
        lock.withLock { _ = values.remove(value) }
    }

    func removeAll(withPrefix prefix: String) {
        lock.withLock { values = values.filter { !$0.hasPrefix(prefix) } }
    }
}

enum SuwayomiTrackerError: Error {
    case invalidId
    case getStateFailed
}
