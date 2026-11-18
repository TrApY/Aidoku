//
//  DownloadsSettings.swift
//  Aidoku
//
//  Created by skitty on 8/29/26.
//

struct DownloadsSettings: Sendable {
    var keys: [any SettingsDefault] {
        [
            compress,
            parallel,
            background,
            downloadOnlyOnWifi,
            deleteDownloadAfterReading,
            downloadAheadBatches,
            downloadAheadRefillAt
        ]
    }

    let compress = SettingsKey<Bool>("Downloads.compress", default: true)
    let parallel = SettingsKey<Bool>("Downloads.parallel", default: true)
    let background = SettingsKey<Bool>("Downloads.background", default: true)

    let downloadOnlyOnWifi = SettingsKey<Bool>("Library.downloadOnlyOnWifi", default: false)
    let deleteDownloadAfterReading = SettingsKey<Bool>("Library.deleteDownloadAfterReading", default: false)

    /// «Descarga adelantada» por tandas (global; the number of chapters ahead is per manga): see
    /// `DownloadAheadSetting.batchRefillAt(target:)`.
    let downloadAheadBatches = SettingsKey<Bool>("Downloads.downloadAheadBatches", default: false)
    /// Batch mode: download again when this many (0...4) of the window are left.
    let downloadAheadRefillAt = SettingsKey<Int>("Downloads.downloadAheadRefillAt", default: 1)
}
