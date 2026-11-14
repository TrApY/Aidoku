//
//  PillarboxSettings.swift
//  Aidoku
//
//  Pillarbox margin per orientation (webtoon reader): one amount for portrait and one for landscape,
//  0 = no pillarbox in that orientation.
//

import Foundation

enum PillarboxSettings {
    static let enabledKey = "Reader.pillarbox"
    static let portraitKey = "Reader.pillarboxAmountPortrait"
    static let landscapeKey = "Reader.pillarboxAmountLandscape"
    /// Set once the old amount + orientation have been turned into the two amounts.
    static let migratedKey = "Reader.pillarboxAmountsMigrated"
    static let defaultAmount = 15
    static let maximumAmount: CGFloat = 95

    /// Margin (percent of the width) for the current orientation, within 0...95.
    static func amount(isPortrait: Bool, portrait: CGFloat, landscape: CGFloat) -> CGFloat {
        min(max(isPortrait ? portrait : landscape, 0), maximumAmount)
    }

    /// Fraction of the width the page keeps, or nil without pillarbox (off, or 0 for this orientation).
    static func widthFraction(enabled: Bool, isPortrait: Bool, portrait: CGFloat, landscape: CGFloat) -> CGFloat? {
        guard enabled else { return nil }
        let amount = amount(isPortrait: isPortrait, portrait: portrait, landscape: landscape)
        guard amount > 0 else { return nil }
        return (100 - amount) / 100
    }

    /// Turns the old `Reader.pillarboxAmount` + `Reader.pillarboxOrientation` into the two amounts, once.
    /// Reads only what is stored in `domain` (registered defaults don't count as set); the old keys stay.
    static func migrate(
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let stored = domain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        // old defaults: 15, both
        let amount = (stored["Reader.pillarboxAmount"] as? NSNumber)?.doubleValue ?? Double(defaultAmount)
        let orientation = stored["Reader.pillarboxOrientation"] as? String ?? "both"
        if stored[portraitKey] == nil {
            defaults.set(orientation == "both" || orientation == "portrait" ? amount : 0, forKey: portraitKey)
        }
        if stored[landscapeKey] == nil {
            defaults.set(orientation == "both" || orientation == "landscape" ? amount : 0, forKey: landscapeKey)
        }
        defaults.set(true, forKey: migratedKey)
    }

    /// After restoring a backup's settings: a backup from before the two amounts brings the old amount and
    /// orientation but not the new keys, so migrate again from what it brought.
    static func restoredFromBackup(
        keys: Set<String>,
        defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) {
        let bringsOld = keys.contains("Reader.pillarboxAmount") || keys.contains("Reader.pillarboxOrientation")
        let bringsNew = keys.contains(portraitKey) || keys.contains(landscapeKey)
        guard bringsOld && !bringsNew else { return }
        defaults.removeObject(forKey: migratedKey)
        defaults.removeObject(forKey: portraitKey)
        defaults.removeObject(forKey: landscapeKey)
        migrate(defaults: defaults, domain: domain)
    }

    /// New value from a settings notification (the stepper posts a Double).
    static func value(from object: Any?, key: String) -> CGFloat {
        if let double = object as? Double { return CGFloat(double) }
        if let int = object as? Int { return CGFloat(int) }
        return CGFloat(UserDefaults.standard.double(forKey: key))
    }
}
