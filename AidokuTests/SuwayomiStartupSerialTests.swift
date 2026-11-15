//
//  SuwayomiStartupSerialTests.swift
//  AidokuTests
//
//  SUWA-12 D B4: the resync from Extensiones and the start's sync and conversion never run at once.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

private actor EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

struct SuwayomiStartupSerialTests {
    @Test func workQueuedInTheStartupActorNeverOverlaps() async throws {
        let startup = SuwayomiStartup()
        let log = EventLog()
        async let first: Void = startup.serially {
            await log.add("conversión+")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await log.add("conversión-")
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        async let second: Void = startup.serially {
            await log.add("resync+")
            await log.add("resync-")
        }
        _ = await (first, second)
        #expect(await log.events == ["conversión+", "conversión-", "resync+", "resync-"])
    }
}
