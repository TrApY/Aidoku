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

    @Test func oneTaskPerSourceWithResumeStartAndAddAtTheSameTime() async {
        defer { cleanUp() }
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        await queue.add(chapters: (1...3).map { .init(key: "c\($0)", chapterNumber: Float($0)) }, manga: manga, start: .never)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { await queue.resume() }
                group.addTask { await queue.start() }
                group.addTask {
                    await queue.add(chapters: [.init(key: "n\(i)", chapterNumber: Float(10 + i))], manga: self.manga, start: .always)
                }
            }
        }
        // tasks of a source come and go (this source doesn't exist), but never two at once
        #expect(await queue.maxAliveTasksPerSource == 1)
    }

    @Test func wifiBackDoesNotOverrideAUserPause() async {
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        #expect(!(await queue.resume(unlessUserPaused: true)))
        #expect(await queue.isPaused())
        #expect(await queue.isPausedByUser())
        // paused by the Wi-Fi rule: it resumes
        await queue.resume()
        await queue.pause(byUser: false)
        #expect(await queue.resume(unlessUserPaused: true))
        #expect(!(await queue.isPaused()))
    }

    /// Running task for a server that never answers, paused; everything of the source cancelled; then a
    /// new download: it must reach that (empty) task.
    @Test func downloadsReachTheTaskAfterCancellingWhilePaused() async throws {
        await SourceManager.shared.waitForSourcesLoad()
        let sourceKey = try #require(await SourceManager.shared.createCustomSource(.suwayomi(.init(
            name: "Cola", server: URL(string: "http://10.255.255.1:4567")!, username: "x", password: "x"
        ))))
        let manga = AidokuRunner.Manga(sourceKey: sourceKey, key: "1", title: "Cola")
        defer {
            DownloadManager.directory.appendingPathComponent(sourceKey).removeItem()
        }
        let queue = await makeQueue()
        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .always)
        await queue.pause(byUser: true)
        await queue.cancelDownloads(for: [.init(sourceKey: sourceKey, mangaKey: "1", chapterKey: "c1")])
        var left = await queue.queue[sourceKey]
        for _ in 0..<40 where left != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            left = await queue.queue[sourceKey]
        }
        #expect(left == nil)
        #expect(await queue.taskChapterKeys(sourceKey: sourceKey)?.isEmpty == true) // the task is still there
        await queue.add(chapters: [.init(key: "c2", chapterNumber: 2)], manga: manga, start: .never)
        #expect(await queue.taskChapterKeys(sourceKey: sourceKey) == ["c2"])
        await queue.cancelDownloads(for: [.init(sourceKey: sourceKey, mangaKey: "1", chapterKey: "c2")])
        await SourceManager.shared.remove(sourceKey: sourceKey)
    }
}
