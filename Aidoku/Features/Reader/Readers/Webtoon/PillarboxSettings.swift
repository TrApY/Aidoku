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
        0 // pending
    }

    /// Fraction of the width the page keeps, or nil without pillarbox (off, or 0 for this orientation).
    static func widthFraction(enabled: Bool, isPortrait: Bool, portrait: CGFloat, landscape: CGFloat) -> CGFloat? {
        nil // pending
    }

    /// Turns the old `Reader.pillarboxAmount` + `Reader.pillarboxOrientation` into the two amounts, once.
    /// Must run before the app registers its defaults (so missing keys read as missing); the old keys stay.
    static func migrate(defaults: UserDefaults = .standard) {
        // pending
    }

    /// New value from a settings notification (the stepper posts a Double).
    static func value(from object: Any?, key: String) -> CGFloat {
        if let double = object as? Double { return CGFloat(double) }
        if let int = object as? Int { return CGFloat(int) }
        return CGFloat(UserDefaults.standard.double(forKey: key))
    }
}
