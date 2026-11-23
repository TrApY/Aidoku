//
//  LibrarySkipTitlesMigration.swift
//  Aidoku
//
//  SUWA-34: the library refresh used to skip series with unread chapters and series not started by default,
//  so new chapters never arrived for them. The default is now only «completed»; a value stored by the old
//  default loses `hasUnread` and `notStarted` once.
//

import Foundation

enum LibrarySkipTitlesMigration {
    /// Set once the stored value has been looked at.
    static let migratedKey = "Library.skipTitles.suwa34Migrated"

    /// The stored skip options without `hasUnread` and `notStarted` (nil stays nil: no stored value).
    static func migratedSkipTitles(_ stored: [String]?) -> [String]? {
        stored
    }

    /// Migrates the value stored in `domain` (registered defaults don't count as stored), once.
    static func migrate(
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) {
    }
}
