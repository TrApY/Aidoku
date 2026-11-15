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

    /// A running task (its source waits until the test lets it go, no network), paused; everything of the
    /// source cancelled; then a new download: it must reach that task, left with nothing.
    @Test func downloadsReachTheTaskAfterCancellingWhilePaused() async throws {
        let gate = PageListGate()
        let source = AidokuRunner.Source(
            key: "downloadqueuetest.blocking",
            name: "Cola",
            version: 1,
            contentRating: .safe,
            runner: BlockingRunner(gate: gate)
        )
        let manga = AidokuRunner.Manga(sourceKey: source.key, key: UUID().uuidString, title: "Cola")
        let queue = await MainActor.run {
            DownloadQueue(cache: DownloadCache(), stateKey: nil, sourceLookup: { $0 == source.key ? source : nil })
        }
        defer {
            Task { await gate.open() } // the waiting page list fails, the task sees it was cancelled
            DownloadManager.directory.appendingPathComponent(source.key).removeItem()
        }
        let chapter = { (key: String) in ChapterIdentifier(sourceKey: source.key, mangaKey: manga.key, chapterKey: key) }

        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .always)
        #expect(await gate.waitUntilEntered(seconds: 10)) // c1 is downloading
        await queue.pause(byUser: true)
        await queue.cancelDownloads(for: [chapter("c1")])
        var left = await queue.queue[source.key]
        for _ in 0..<100 where left != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            left = await queue.queue[source.key]
        }
        #expect(left == nil)
        #expect(await queue.taskChapterKeys(sourceKey: source.key)?.isEmpty == true) // the task is still there

        await queue.add(chapters: [.init(key: "c2", chapterNumber: 2)], manga: manga, start: .never)
        #expect(await queue.taskChapterKeys(sourceKey: source.key) == ["c2"])
        await queue.cancelDownloads(for: [chapter("c2")])
    }

    @Test func waitingForAnEmptyQueueDoesNotSpin() async throws {
        defer { cleanUp() }
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .never)
        let task = FakeBackgroundTask()
        let completion = BackgroundTaskCompletion { _ in }
        let first = WaitResult()
        Task { await first.set(await queue.waitUntilEmpty(for: task, completion: completion)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await first.value == nil) // still waiting: the queue has a download
        await queue.cancelDownloads(for: [.init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1")])
        #expect(await first.wait(seconds: 5) == true)

        // the background task expiring ends the wait
        await queue.add(chapters: [.init(key: "c2", chapterNumber: 2)], manga: manga, start: .never)
        let second = WaitResult()
        Task { await second.set(await queue.waitUntilEmpty(for: task, completion: completion)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await queue.backgroundTaskExpired(task)
        #expect(await second.wait(seconds: 5) == false)
        await queue.cancelDownloads(for: [.init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c2")])
    }

    /// The system expires the background task before its wait starts (e.g. while the tasks are resumed):
    /// the wait must not hang until the queue empties hours later.
    @Test func anExpiryBeforeTheWaitEndsIt() async throws {
        defer { cleanUp() }
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .never)
        let task = FakeBackgroundTask()
        let log = CompletionLog()
        let completion = BackgroundTaskCompletion { success in log.add(success) }
        await queue.setBackgroundTask(task)
        await queue.backgroundTaskWillExpire(task, completion: completion, pause: {}).value
        let late = WaitResult()
        Task { await late.set(await queue.waitUntilEmpty(for: task, completion: completion)) }
        #expect(await late.wait(seconds: 3) == false)
        #expect(log.calls == [false])
        #expect(!(await queue.isCurrentBackgroundTask(task)))
        await queue.cancelDownloads(for: [.init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1")])
    }

    /// Two waits at once: the expiry of one task leaves the other waiting until the queue empties.
    @Test func anExpiryOnlyEndsItsOwnWait() async throws {
        defer { cleanUp() }
        let queue = await makeQueue()
        await queue.pause(byUser: true)
        await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .never)
        let expiring = FakeBackgroundTask()
        let staying = FakeBackgroundTask()
        let expiringCompletion = BackgroundTaskCompletion { _ in }
        let stayingCompletion = BackgroundTaskCompletion { _ in }
        let expiringResult = WaitResult()
        let stayingResult = WaitResult()
        Task { await expiringResult.set(await queue.waitUntilEmpty(for: expiring, completion: expiringCompletion)) }
        Task { await stayingResult.set(await queue.waitUntilEmpty(for: staying, completion: stayingCompletion)) }
        #expect(await waitForWaiters(queue, 2))
        await queue.backgroundTaskWillExpire(expiring, completion: expiringCompletion, pause: {}).value
        #expect(await expiringResult.wait(seconds: 3) == false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await stayingResult.value == nil) // still waiting
        await queue.cancelDownloads(for: [.init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1")])
        #expect(await stayingResult.wait(seconds: 5) == true)
    }

    /// The expiry and the queue emptying at about the same time: the task is completed exactly once.
    @Test func theTaskIsCompletedExactlyOnce() async throws {
        defer { cleanUp() }
        for round in 0..<60 {
            let queue = await makeQueue()
            await queue.pause(byUser: true)
            await queue.add(chapters: [.init(key: "c1", chapterNumber: 1)], manga: manga, start: .never)
            let task = FakeBackgroundTask()
            let log = CompletionLog()
            let completion = BackgroundTaskCompletion { success in log.add(success) }
            await queue.setBackgroundTask(task)
            let run = Task { await queue.completeWhenEmpty(task, completion: completion) }
            #expect(await waitForWaiters(queue, 1))
            let empty = Task {
                await queue.cancelDownloads(for: [.init(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "c1")])
            }
            if round % 2 == 0 { await empty.value } // emptied first, the expiry right behind
            let expiry = queue.backgroundTaskWillExpire(task, completion: completion, pause: {})
            await empty.value
            await expiry.value
            await run.value
            #expect(log.calls.count == 1, "round \(round): \(log.calls)")
            #expect(!(await queue.isCurrentBackgroundTask(task)))
        }
    }

    /// An expiry after the wait ended (downloads done) keeps nothing: the system's task is let go.
    @Test func aLateExpiryKeepsNothing() async throws {
        let queue = await makeQueue()
        weak var weakTask: FakeBackgroundTask?
        let log = CompletionLog()
        do {
            let task = FakeBackgroundTask()
            weakTask = task
            let completion = BackgroundTaskCompletion { success in log.add(success) }
            await queue.setBackgroundTask(task)
            await queue.completeWhenEmpty(task, completion: completion) // empty queue: done at once
            await queue.backgroundTaskWillExpire(task, completion: completion, pause: {}).value
        }
        #expect(log.calls == [true])
        #expect(weakTask == nil)
    }

    private func waitForWaiters(_ queue: DownloadQueue, _ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while await queue.emptyWaiterCount < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await queue.emptyWaiterCount == count
    }

    /// An old background task that wakes up late doesn't touch the current one.
    @Test func onlyTheCurrentBackgroundTaskIsFinished() async {
        let queue = await makeQueue()
        let old = FakeBackgroundTask()
        let new = FakeBackgroundTask()
        await queue.setBackgroundTask(old)
        await queue.setBackgroundTask(new)
        #expect(!(await queue.finishBackgroundTask(old)))
        #expect(await queue.isCurrentBackgroundTask(new))
        #expect(await queue.finishBackgroundTask(new))
        #expect(!(await queue.isCurrentBackgroundTask(new)))
    }
}

/// Lets a page list request wait until the test opens it.
private actor PageListGate {
    private var isOpen = false
    private var entered = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async throws {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        if !isOpen {
            await withCheckedContinuation { waiting.append($0) }
        }
        throw CancellationError()
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func waitUntilEntered(seconds: Double) async -> Bool {
        if entered { return true }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.giveUp()
        }
        await withCheckedContinuation { enteredWaiters.append($0) }
        timeout.cancel()
        return entered
    }

    private func giveUp() {
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
    }
}

/// A source whose page list waits at the gate (then fails).
private final class BlockingRunner: AidokuRunner.Runner, @unchecked Sendable {
    let gate: PageListGate
    let features = AidokuRunner.SourceFeatures()

    init(gate: PageListGate) {
        self.gate = gate
    }

    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }

    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        try await gate.pass()
        return []
    }
}

/// What a wait returned (nil while it hasn't).
private actor WaitResult {
    private(set) var value: Bool?
    func set(_ value: Bool) { self.value = value }

    /// Polls up to `seconds` (never blocks on the wait itself).
    func wait(seconds: Double) async -> Bool? {
        let deadline = Date().addingTimeInterval(seconds)
        while value == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return value
    }
}

/// Stands in for the system's background task.
private final class FakeBackgroundTask: NSObject, ProgressReporting, @unchecked Sendable {
    let progress = Progress()
}

/// The completions a background task got.
private final class CompletionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var calls: [Bool] { lock.withLock { stored } }
    func add(_ success: Bool) { lock.withLock { stored.append(success) } }
}
