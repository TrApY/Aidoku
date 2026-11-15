//
//  SuwayomiApi.swift
//  Aidoku
//
//  Created by skitty on 7/8/26.
//

import Foundation

actor SuwayomiApi {
    private let transport: SuwayomiHelper.Transport?

    init(transport: SuwayomiHelper.Transport? = nil) {
        self.transport = transport
    }

    private func makeHelper(sourceKey: String) -> SuwayomiHelper {
        if let transport {
            .init(sourceKey: sourceKey, transport: transport)
        } else {
            .init(sourceKey: sourceKey)
        }
    }

    func getState(sourceKey: String, seriesId: String) async throws -> TrackState? {
        guard let mangaId = Int(seriesId) else { throw SuwayomiTrackerError.invalidId }

        struct Payload: Encodable {
            let variables: Variables
            let query = """
                query GetTrackState($mangaId: Int!) {
                  manga(id: $mangaId) {
                    chapters {
                      totalCount
                    }
                    latestReadChapter {
                      chapterNumber
                    }
                    highestNumberedChapter {
                      chapterNumber
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let mangaId: Int
            }
        }

        let helper = makeHelper(sourceKey: sourceKey)
        let response: SuwayomiTrackStateResponse = try await helper.request(body: Payload(variables: .init(mangaId: mangaId)))

        return .init(
            lastReadChapter: response.data.manga.latestReadChapter?.chapterNumber,
            totalChapters: response.data.manga.highestNumberedChapter?.chapterNumber.flatMap { Int(floor($0)) }
                ?? response.data.manga.chapters.totalCount
        )
    }

    /// Marks the manga as in the server library if it isn't already.
    func addToLibrary(sourceKey: String, seriesId: String) async throws {
        guard let mangaId = Int(seriesId) else { throw SuwayomiTrackerError.invalidId }
        let helper = makeHelper(sourceKey: sourceKey)
        let state: SuwayomiInLibraryResponse = try await helper.request(
            body: SuwayomiInLibraryPayload(variables: .init(id: mangaId))
        )
        guard !state.data.manga.inLibrary else { return }
        let _: SuwayomiUpdateMangaResponse = try await helper.request(
            body: SuwayomiAddToLibraryPayload(variables: .init(id: mangaId))
        )
    }

    func update(sourceKey: String, seriesId: String, update: TrackUpdate) async throws {
        guard
            let mangaId = Int(seriesId),
            let lastReadChapter = update.lastReadChapter
        else {
            return
        }

        // only the unread chapters up to that number (floor(number) <= last read, i.e. number < below):
        // the tracker knows the number, not the chapter ids
        struct GetChaptersPayload: Encodable {
            let variables: Variables
            let query = """
                query GetChaptersForTrackUpdate($mangaId: Int!, $below: Float!) {
                  chapters(
                    condition: {mangaId: $mangaId}
                    filter: {chapterNumber: {lessThan: $below}, isRead: {equalTo: false}}
                  ) {
                    nodes {
                      id
                      chapterNumber
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let mangaId: Int
                let below: Float
            }
        }

        let helper = makeHelper(sourceKey: sourceKey)
        let chapters: SuwayomiTrackChaptersResponse = try await helper.request(
            body: GetChaptersPayload(variables: .init(mangaId: mangaId, below: floor(lastReadChapter) + 1))
        )
        let ids = chapters.data.chapters.nodes
            .filter { floor($0.chapterNumber ?? 0) <= lastReadChapter }
            .map(\.id)
        guard !ids.isEmpty else { return }

        struct UpdatePayload: Encodable {
            let variables: Variables
            let query = """
                mutation MarkChaptersRead($ids: [Int!]!, $patch: UpdateChapterPatchInput!) {
                  updateChapters(input: {ids: $ids, patch: $patch}) {
                    chapters {
                      id
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let ids: [Int]
                let patch: SuwayomiChapterProgressPatch
            }
        }

        let _: SuwayomiUpdateChaptersResponse = try await helper.request(
            body: UpdatePayload(variables: .init(ids: ids, patch: .init(isRead: true)))
        )
    }

    func updateReadProgress(
        sourceKey: String,
        seriesId: Int,
        chapterId: Int,
        progress: ChapterReadProgress
    ) async throws {
        struct Payload: Encodable {
            let variables: Variables
            let query = """
                mutation UpdateChapterProgress($chapterId: Int!, $patch: UpdateChapterPatchInput!) {
                  updateChapter(input: {id: $chapterId, patch: $patch}) {
                    chapter {
                      id
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let chapterId: Int
                let patch: SuwayomiChapterProgressPatch
            }
        }

        let lastPageRead = max(progress.page - 1, 0)
        let patch = SuwayomiChapterProgressPatch(
            isRead: progress.completed,
            lastPageRead: lastPageRead
        )
        let helper = makeHelper(sourceKey: sourceKey)
        let _: SuwayomiUpdateChapterResponse = try await helper.request(body: Payload(variables: .init(chapterId: chapterId, patch: patch)))
    }

    func getSeriesReadProgress(sourceKey: String, seriesId: String) async throws -> [String: ChapterReadProgress] {
        guard let mangaId = Int(seriesId) else { throw SuwayomiTrackerError.invalidId }

        struct Payload: Encodable {
            let variables: Variables
            let query = """
                query GetSeriesReadProgress($mangaId: Int!) {
                  chapters(condition: {mangaId: $mangaId}) {
                    nodes {
                      id
                      isRead
                      lastPageRead
                      lastReadAt
                      pageCount
                    }
                  }
                }
                """

            struct Variables: Encodable {
                let mangaId: Int
            }
        }

        let helper = makeHelper(sourceKey: sourceKey)
        let response: SuwayomiReadProgressResponse = try await helper.request(body: Payload(variables: .init(mangaId: mangaId)))

        var result: [String: ChapterReadProgress] = [:]
        for chapter in response.data.chapters.nodes {
            guard chapter.isRead || chapter.lastPageRead > 0 else { continue }
            result["\(chapter.id)"] = .init(
                completed: chapter.isRead,
                page: chapter.isRead ? max(chapter.pageCount, chapter.lastPageRead + 1) : chapter.lastPageRead + 1,
                date: Date(suwayomiTimestamp: chapter.lastReadAt)
            )
        }
        return result
    }
}
