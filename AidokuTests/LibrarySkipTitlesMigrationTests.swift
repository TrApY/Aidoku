//
//  LibrarySkipTitlesMigrationTests.swift
//  AidokuTests
//
//  SUWA-34 P4: `Library.skipTitles` defaults to only «completed»; a value stored by the old default
//  (hasUnread, completed, notStarted) loses hasUnread and notStarted, once.
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct LibrarySkipTitlesMigrationTests {
    private let key = AppSettings.library.skipTitles.key
    private let marker = LibrarySkipTitlesMigration.migratedKey

    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let name = "LibrarySkipTitlesMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults, name)
    }

    /// Stores `value` (nil: nothing), runs the step and reads the stored value back.
    private func migrated(storing value: [String]?) -> (stored: [String]?, marked: Bool) {
        var result: (stored: [String]?, marked: Bool) = (nil, false)
        withDefaults { defaults, domain in
            if let value { defaults.set(value, forKey: key) }
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            result = (defaults.persistentDomain(forName: domain)?[key] as? [String], defaults.bool(forKey: marker))
        }
        return result
    }

    // MARK: Default

    @Test func theDefaultIsOnlyCompleted() {
        #expect(AppSettings.library.skipTitles.defaultValue == ["completed"])
    }

    // MARK: Pure function

    @Test func theFunctionDropsHasUnreadAndNotStarted() {
        #expect(LibrarySkipTitlesMigration.migratedSkipTitles(["hasUnread", "completed", "notStarted"]) == ["completed"])
        #expect(LibrarySkipTitlesMigration.migratedSkipTitles(["hasUnread"]) == [])
        #expect(LibrarySkipTitlesMigration.migratedSkipTitles(["notStarted", "hasUnread"]) == [])
        #expect(LibrarySkipTitlesMigration.migratedSkipTitles(["completed"]) == ["completed"])
        #expect(LibrarySkipTitlesMigration.migratedSkipTitles([]) == [])
        #expect(LibrarySkipTitlesMigration.migratedSkipTitles(nil) == nil)
    }

    // MARK: Step

    @Test func theOldDefaultBecomesCompletedAndIsMarked() {
        let result = migrated(storing: ["hasUnread", "completed", "notStarted"])
        #expect(result.stored == ["completed"])
        #expect(result.marked)
    }

    @Test func onlyHasUnreadBecomesEmpty() {
        let result = migrated(storing: ["hasUnread"])
        #expect(result.stored == [])
        #expect(result.marked)
    }

    @Test func completedStaysCompleted() {
        let result = migrated(storing: ["completed"])
        #expect(result.stored == ["completed"])
        #expect(result.marked)
    }

    @Test func withoutAStoredValueOnlyTheMarkIsSet() {
        let result = migrated(storing: nil)
        #expect(result.stored == nil) // the key is not written: the new default applies
        #expect(result.marked)
    }

    @Test func afterTheMarkALaterChoiceIsRespected() {
        withDefaults { defaults, domain in
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            #expect(defaults.bool(forKey: marker))
            defaults.set(["hasUnread"], forKey: key) // the user chooses it afterwards
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            #expect(defaults.stringArray(forKey: key) == ["hasUnread"])
        }
    }

    @Test func aMarkedStoreIsNotTouchedEvenWithTheOldValue() {
        withDefaults { defaults, domain in
            defaults.set(true, forKey: marker)
            defaults.set(["hasUnread", "completed", "notStarted"], forKey: key)
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            #expect(defaults.stringArray(forKey: key) == ["hasUnread", "completed", "notStarted"])
        }
    }

    @Test func aMerelyRegisteredValueDoesNotCountAsStored() {
        withDefaults { defaults, domain in
            defaults.register(defaults: [key: ["hasUnread", "completed", "notStarted"]])
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            #expect(defaults.persistentDomain(forName: domain)?[key] == nil) // nothing written
            #expect(defaults.bool(forKey: marker))
        }
    }

    @Test func aSecondRunChangesNothing() {
        withDefaults { defaults, domain in
            defaults.set(["hasUnread", "completed", "notStarted"], forKey: key)
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            LibrarySkipTitlesMigration.migrate(defaults: defaults, domain: domain)
            #expect(defaults.stringArray(forKey: key) == ["completed"])
        }
    }
}
