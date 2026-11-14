//
//  DownloadQueueTests.swift
//  AidokuTests
//
//  The download queue on its own (own cache, queue not saved), with a source that doesn't exist:
//  a started task skips its downloads at once, nothing touches the network.
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

struct DownloadQueueTests {
    private let manga = AidokuRunner.Manga(sourceKey: "downloadqueuetest", key: UUID().uuidString, title: "Cola")

    @MainActor
    private func makeQueue() -> DownloadQueue {
        DownloadQueue(cache: DownloadCache(), stateKey: nil)
    }

    private func cleanUp() {
        DownloadManager.directory.appendingPathComponent(manga.sourceKey).appendingPathComponent(manga.key).removeItem()
    }

    private func queued(_ queue: DownloadQueue) async -> [String] {
        await queue.queue[manga.sourceKey]?.map(\.chapterIdentifier.chapterKey) ?? []
    }

    @Test func resumeCreatesTheTasksOfDownloadsQueuedWhilePaused() async throws {
        defer { cleanUp() }
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .never)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await queued(queue) == ["c1"]) // waiting, no task
        #expect(await queue.taskChapterKeys(sourceKey: manga.sourceKey) == nil)
        await queue.resume()
        // the new task runs it (the source doesn't exist, so it's skipped right away)
        var left = await queued(queue)
        for _ in 0..<40 where !left.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
            left = await queued(queue)
        }
        #expect(left.isEmpty)
    }

    @Test func userPauseAndSystemPause() async {
        defer { cleanUp() }
        let queue = await makeQueue()
        // paused by the system (background task expired, Wi-Fi rule): automatic downloads start it
        await queue.pause(byUser: false)
        #expect(await queue.isPaused())
        #expect(!(await queue.isPausedByUser()))
        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .unlessUserPaused)
        #expect(!(await queue.isPaused()))

        // paused by the user: automatic downloads are queued, the queue stays paused
        await queue.pause(byUser: true)
        #expect(await queue.isPausedByUser())
        await queue.add(chapters: [.init(key: "c2", chapterNumber: 2)], manga: manga, start: .unlessUserPaused)
        #expect(await queue.isPaused())
        #expect(await queued(queue).contains("c2"))

        // resuming clears it
        await queue.resume()
        #expect(!(await queue.isPausedByUser()))
        #expect(!(await queue.isPaused()))
    }

    @Test func oneTaskPerSourceEvenWhenAskedAtTheSameTime() async {
        let queue = await makeQueue()
        async let a = queue.makeTaskIfNeeded(sourceKey: manga.sourceKey)
        async let b = queue.makeTaskIfNeeded(sourceKey: manga.sourceKey)
        async let c = queue.makeTaskIfNeeded(sourceKey: manga.sourceKey)
        let tasks = await [a, b, c]
        #expect(tasks[0] === tasks[1])
        #expect(tasks[1] === tasks[2])
    }

    @Test func downloadsReachAnExistingTaskWithNothingQueued() async {
        defer { cleanUp() }
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        // a task left with nothing (everything of the source cancelled while paused)
        await queue.makeTaskIfNeeded(sourceKey: manga.sourceKey)
        #expect(await queued(queue).isEmpty)
        await queue.add(chapters: [.init(key: "c3", chapterNumber: 3)], manga: manga, start: .never)
        #expect(await queue.taskChapterKeys(sourceKey: manga.sourceKey) == ["c3"])
    }
}
