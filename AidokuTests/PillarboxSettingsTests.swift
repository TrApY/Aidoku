//
//  PillarboxSettingsTests.swift
//  AidokuTests
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct PillarboxSettingsTests {
    // MARK: Amount per orientation

    @Test func amountFollowsTheOrientation() {
        #expect(PillarboxSettings.amount(isPortrait: true, portrait: 10, landscape: 30) == 10)
        #expect(PillarboxSettings.amount(isPortrait: false, portrait: 10, landscape: 30) == 30)
        #expect(PillarboxSettings.amount(isPortrait: true, portrait: 95, landscape: 0) == 95)
        #expect(PillarboxSettings.amount(isPortrait: true, portrait: 120, landscape: 0) == 95) // clamped
        #expect(PillarboxSettings.amount(isPortrait: false, portrait: 10, landscape: -5) == 0)
    }

    @Test func widthFraction() throws {
        let portrait = try #require(PillarboxSettings.widthFraction(enabled: true, isPortrait: true, portrait: 10, landscape: 30))
        #expect(abs(portrait - 0.9) < 0.0001)
        let landscape = try #require(PillarboxSettings.widthFraction(enabled: true, isPortrait: false, portrait: 10, landscape: 30))
        #expect(abs(landscape - 0.7) < 0.0001)
        let maximum = try #require(PillarboxSettings.widthFraction(enabled: true, isPortrait: true, portrait: 95, landscape: 0))
        #expect(abs(maximum - 0.05) < 0.0001)
        // 0 in this orientation, or pillarbox off: no pillarbox
        #expect(PillarboxSettings.widthFraction(enabled: true, isPortrait: false, portrait: 95, landscape: 0) == nil)
        #expect(PillarboxSettings.widthFraction(enabled: false, isPortrait: true, portrait: 10, landscape: 30) == nil)
    }

    // MARK: Migration

    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let name = "PillarboxSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults, name)
    }

    private func migrated(amount: Int?, orientation: String?) -> (portrait: Int, landscape: Int, oldKept: Bool) {
        var result = (portrait: -1, landscape: -1, oldKept: false)
        withDefaults { defaults, domain in
            if let amount { defaults.set(Double(amount), forKey: "Reader.pillarboxAmount") }
            if let orientation { defaults.set(orientation, forKey: "Reader.pillarboxOrientation") }
            PillarboxSettings.migrate(defaults: defaults, domain: domain)
            result = (
                defaults.integer(forKey: PillarboxSettings.portraitKey),
                defaults.integer(forKey: PillarboxSettings.landscapeKey),
                (amount == nil || defaults.object(forKey: "Reader.pillarboxAmount") != nil)
                    && (orientation == nil || defaults.object(forKey: "Reader.pillarboxOrientation") != nil)
            )
        }
        return result
    }

    @Test func migrationForEachOrientation() {
        #expect(migrated(amount: 25, orientation: "both") == (25, 25, true))
        #expect(migrated(amount: 25, orientation: "portrait") == (25, 0, true))
        #expect(migrated(amount: 25, orientation: "landscape") == (0, 25, true))
        // never changed: the old defaults (15, both)
        #expect(migrated(amount: nil, orientation: nil) == (15, 15, true))
        #expect(migrated(amount: nil, orientation: "landscape") == (0, 15, true))
    }

    @Test func migrationKeepsExistingValuesAndRunsOnce() {
        withDefaults { defaults, domain in
            defaults.set(40.0, forKey: PillarboxSettings.portraitKey)
            defaults.set(25.0, forKey: "Reader.pillarboxAmount")
            defaults.set("both", forKey: "Reader.pillarboxOrientation")
            PillarboxSettings.migrate(defaults: defaults, domain: domain)
            #expect(defaults.integer(forKey: PillarboxSettings.portraitKey) == 40) // not overwritten
            #expect(defaults.integer(forKey: PillarboxSettings.landscapeKey) == 25)
            #expect(defaults.bool(forKey: PillarboxSettings.migratedKey))

            // marked as done: later changes of the old keys don't migrate again
            defaults.set(5.0, forKey: PillarboxSettings.portraitKey)
            defaults.set(60.0, forKey: "Reader.pillarboxAmount")
            defaults.removeObject(forKey: PillarboxSettings.landscapeKey)
            PillarboxSettings.migrate(defaults: defaults, domain: domain)
            #expect(defaults.integer(forKey: PillarboxSettings.portraitKey) == 5)
            #expect(defaults.persistentDomain(forName: domain)?[PillarboxSettings.landscapeKey] == nil)
        }
    }
}
