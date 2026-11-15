//
//  DownloadFilesTests.swift
//  AidokuTests
//

import Foundation
import Testing

@testable import Aidoku

struct DownloadFilesTests {
    private func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    @Test func downloadsAreKeptOutOfTheBackup() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads-\(UUID().uuidString)", isDirectory: true)
        defer { url.removeItem() }
        DownloadManager.prepareDirectory(url)
        #expect(url.exists)
        #expect(isExcluded(url))
        // removed (e.g. «delete all downloads») and created again: still excluded
        url.removeItem()
        DownloadManager.prepareDirectory(url)
        #expect(isExcluded(url))
        // an existing directory from an older version gets the mark too
        let old = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads-\(UUID().uuidString)", isDirectory: true)
        defer { old.removeItem() }
        old.createDirectory()
        #expect(!isExcluded(old))
        DownloadManager.prepareDirectory(old)
        #expect(isExcluded(old))
    }

    @Test func pagesAreNotCachedTwice() {
        let session = DownloadTask.downloadSession
        #expect(session !== URLSession.shared)
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        // same cookies and credentials as before (logged-in sources)
        #expect(session.configuration.httpCookieStorage === HTTPCookieStorage.shared)
        #expect(session.configuration.urlCredentialStorage === URLCredentialStorage.shared)
    }
}
