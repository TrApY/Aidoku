//
//  DownloadsSettingsListTests.swift
//  AidokuTests
//
//  SUWA-28 B4: Ajustes › Descargas lists its groups with `ForEach(Settings.downloadSettings, id: \.listID)`. With
//  two groups of the same empty key («Configuración» and «Descarga adelantada») SwiftUI showed the first one twice.
//

import AidokuRunner
import Testing

@testable import Aidoku

@Suite struct DownloadsSettingsListTests {
    @Test func everyDownloadsGroupHasItsOwnListID() {
        let ids = Settings.downloadSettings.map { $0.listID }
        #expect(ids.count == 2)
        #expect(Set(ids).count == ids.count)
    }

    @Test func settingsWithAKeyKeepItAsTheirID() {
        let toggle = Setting(key: "Downloads.compress", title: "x", value: .toggle(.init()))
        #expect(toggle.listID == "Downloads.compress")
        let groups = [
            Setting(title: "A", value: .group(.init(items: []))),
            Setting(title: "B", value: .group(.init(items: [])))
        ]
        #expect(groups[0].listID != groups[1].listID)
    }
}
