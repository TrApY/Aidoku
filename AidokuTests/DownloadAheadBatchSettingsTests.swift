//
//  DownloadAheadBatchSettingsTests.swift
//  AidokuTests
//
//  SUWA-28 B3: Ajustes › Descargas › «Descarga adelantada» (interruptor «Por tandas» + «Volver a descargar cuando
//  queden» 0...4, which needs the switch) and the manga page's indicator («Descarga adelantada: 5 · por tandas»).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite struct DownloadAheadBatchSettingsTests {
    private static let batchesKey = "Downloads.downloadAheadBatches"
    private static let refillAtKey = "Downloads.downloadAheadRefillAt"

    /// The value of `key` in the app's `lang` strings table.
    private func localized(_ key: String, _ lang: String) throws -> String {
        let path = try #require(Bundle.main.path(forResource: lang, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: "<falta>", table: nil)
    }

    @Test func downloadsSettingsHaveTheGroup() throws {
        let group = Settings.downloadSettings.first { $0.title == NSLocalizedString("DOWNLOAD_AHEAD") }
        #expect(group != nil)
        guard let group, case let .group(value) = group.value else { return }
        #expect(value.footer == NSLocalizedString("DOWNLOAD_AHEAD_BATCHES_TEXT"))
        try #require(value.items.count == 2)

        let toggle = value.items[0]
        #expect(toggle.key == Self.batchesKey)
        #expect(toggle.title == NSLocalizedString("DOWNLOAD_AHEAD_BATCHES"))
        #expect(toggle.requires == nil)
        if case .toggle = toggle.value {} else { Issue.record("«Por tandas» no es un interruptor") }

        let stepper = value.items[1]
        #expect(stepper.key == Self.refillAtKey)
        #expect(stepper.title == NSLocalizedString("DOWNLOAD_AHEAD_REFILL_AT"))
        #expect(stepper.requires == Self.batchesKey) // disabled while the switch is off
        if case let .stepper(range) = stepper.value {
            #expect(range.minimumValue == 0)
            #expect(range.maximumValue == 4)
            #expect((range.stepValue ?? 1) == 1)
        } else {
            Issue.record("«Volver a descargar cuando queden» no es un stepper")
        }
    }

    @Test func settingsKeysAndDefaults() {
        let downloads = AppSettings.downloads
        #expect(downloads.downloadAheadBatches.key == Self.batchesKey)
        #expect(downloads.downloadAheadBatches.defaultValue == false)
        #expect(downloads.downloadAheadRefillAt.key == Self.refillAtKey)
        #expect(downloads.downloadAheadRefillAt.defaultValue == 1)
        // registered with the other defaults (what the settings stepper shows before the first change)
        let keys = downloads.keys.map(\.key)
        #expect(keys.contains(Self.batchesKey))
        #expect(keys.contains(Self.refillAtKey))
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect((registered[Self.batchesKey] as? Bool) == false)
        #expect((registered[Self.refillAtKey] as? Int) == 1)
    }

    @Test func stepperShowsTheValueInWords() throws {
        #expect(DownloadAheadSetting.refillAtText(1) == String(format: NSLocalizedString("DOWNLOAD_AHEAD_REFILL_AT_VALUE"), 1))
        #expect(SettingView.stepperValueText(key: Self.refillAtKey, value: 1) == DownloadAheadSetting.refillAtText(1))
        #expect(SettingView.stepperValueText(key: Self.refillAtKey, value: 0) == DownloadAheadSetting.refillAtText(0))
        #expect(SettingView.stepperValueText(key: "Reader.autoScrollSpeed", value: 3) == nil) // other steppers: the number
        #expect(DownloadAheadSetting.refillAtText(3) != "3")
        #expect(String(format: try localized("DOWNLOAD_AHEAD_REFILL_AT_VALUE", "es"), 1) == "1 sin leer")
        #expect(String(format: try localized("DOWNLOAD_AHEAD_REFILL_AT_VALUE", "es"), 0) == "0 sin leer")
        #expect(String(format: try localized("DOWNLOAD_AHEAD_REFILL_AT_VALUE", "en"), 1) == "1 left")
        #expect(try localized("DOWNLOAD_AHEAD_REFILL_AT", "es") == "Volver a descargar cuando queden")
        #expect(try localized("DOWNLOAD_AHEAD_REFILL_AT", "en") == "Download again when")
        #expect(try localized("DOWNLOAD_AHEAD_BATCHES", "es") == "Por tandas")
        #expect(try localized("DOWNLOAD_AHEAD_BATCHES", "en") == "In batches")
        #expect(try localized("DOWNLOAD_AHEAD_BATCHES_TEXT", "es").hasPrefix("Los capítulos adelantados se eligen en cada manga."))
        #expect(try localized("DOWNLOAD_AHEAD_BATCHES_TEXT", "en") != "<falta>")
    }

    @Test func indicatorSaysInBatches() throws {
        let continuous = String(format: NSLocalizedString("DOWNLOAD_AHEAD_ACTIVE"), 5)
        let batches = String(format: NSLocalizedString("DOWNLOAD_AHEAD_ACTIVE_BATCHES"), 5)
        #expect(DownloadAheadSetting.indicatorText(setting: 5, available: true, batches: false) == continuous)
        #expect(DownloadAheadSetting.indicatorText(setting: 5, available: true, batches: true) == batches)
        #expect(batches != continuous)
        #expect(DownloadAheadSetting.indicatorText(setting: 0, available: true, batches: true) == nil)
        #expect(DownloadAheadSetting.indicatorText(setting: 0, available: true, batches: false) == nil)
        #expect(DownloadAheadSetting.indicatorText(setting: 5, available: false, batches: true) == nil)
        #expect(String(format: try localized("DOWNLOAD_AHEAD_ACTIVE_BATCHES", "es"), 5) == "Descarga adelantada: 5 · por tandas")
        #expect(String(format: try localized("DOWNLOAD_AHEAD_ACTIVE_BATCHES", "en"), 5) == "Download ahead: 5 · in batches")
        #expect(String(format: try localized("DOWNLOAD_AHEAD_ACTIVE", "es"), 5) == "Descarga adelantada: 5")
    }
}
