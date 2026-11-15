//
//  CoreDataTrackRepository.swift
//  Aidoku
//

import CoreData

/// Not an actor (D5): each call runs on its own background context, as the callers did before.
final class CoreDataTrackRepository: TrackRepository, @unchecked Sendable {
    private let container: NSPersistentContainer

    init(container: NSPersistentContainer) {
        self.container = container
    }

    func items(of manga: MangaIdentifier) async -> [TrackItem] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getTracks(mangaId: manga, context: context).map { $0.toItem() }
        }
    }

    func items(trackerId: String) async -> [TrackItem] {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.getTracks(trackerId: trackerId, context: context).map { $0.toItem() }
        }
    }

    func contains(manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasTrack(mangaId: manga, context: context)
        }
    }

    func contains(trackerId: String, manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.hasTrack(trackerId: trackerId, mangaId: manga, context: context)
        }
    }

    @discardableResult
    func add(_ item: TrackItem) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.createTrack(
                id: item.id,
                trackerId: item.trackerId,
                mangaId: item.mangaId,
                title: item.title,
                chapterOffset: item.chapterOffset,
                context: context
            )
            return context.saveLogging("TrackRepository.add")
        }
    }

    @discardableResult
    func setChapterOffset(trackerId: String, manga: MangaIdentifier, offset: Int) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.setTrackChapterOffset(trackerId: trackerId, mangaId: manga, chapterOffset: offset, context: context)
            return context.saveLogging("TrackRepository.setChapterOffset")
        }
    }

    @discardableResult
    func remove(trackerId: String, manga: MangaIdentifier) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.removeTrack(trackerId: trackerId, mangaId: manga, context: context)
            return context.saveLogging("TrackRepository.remove")
        }
    }

    @discardableResult
    func removeAll(trackerId: String) async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.removeTracks(trackerId: trackerId, context: context)
            return context.saveLogging("TrackRepository.removeAll")
        }
    }

    @discardableResult
    func removeAll(trackerId: String, where idMatches: @escaping @Sendable (String) throws -> Bool) async -> Bool {
        await container.performBackgroundTask { context in
            do {
                for object in CoreDataManager.shared.getTracks(trackerId: trackerId, context: context) {
                    guard let id = object.id else { continue }
                    if try idMatches(id) {
                        context.delete(object)
                    }
                }
            } catch {
                LogManager.logger.error("TrackRepository.removeAll(where:): \(error)")
                return false
            }
            return context.saveLogging("TrackRepository.removeAll(where:)")
        }
    }

    @discardableResult
    func clearAll() async -> Bool {
        await container.performBackgroundTask { context in
            CoreDataManager.shared.clearTracks(context: context)
            return context.saveLogging("TrackRepository.clearAll")
        }
    }
}
