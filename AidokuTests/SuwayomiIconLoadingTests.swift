//
//  SuwayomiIconLoadingTests.swift
//  AidokuTests
//
//  SUWA-12 D B5: icons asked with the login only go to the connection's server, never cached on disk.
//

import AidokuRunner
import CoreData
import Foundation
import Testing

@testable import Aidoku

struct SuwayomiIconLoadingTests {
    private let server = URL(string: "https://servidor.example:4567/")!

    private func header(_ url: URL) -> String? {
        SuwayomiIconLoading.request(url, server: server, timeout: 10) {
            $0.setValue("Basic dXN1YXJpbzpjbGF2ZQ==", forHTTPHeaderField: "Authorization")
        }.value(forHTTPHeaderField: "Authorization")
    }

    @Test func anIconOnAnotherDomainGoesWithoutTheLogin() throws {
        #expect(header(try #require(URL(string: "https://otro.example/icon.png"))) == nil)
        #expect(header(try #require(URL(string: "https://servidor.example/icon.png"))) == nil) // another port
        #expect(header(try #require(URL(string: "http://servidor.example:4567/icon.png"))) == nil) // no TLS
        let absolute = try #require(SuwayomiServerSources.iconUrl("https://cdn.example/x.png", baseUrl: server))
        #expect(header(absolute) == nil)
    }

    @Test func anIconOnTheServerGoesWithTheLogin() throws {
        let relative = try #require(SuwayomiServerSources.iconUrl("/api/v1/extension/icon/x.apk", baseUrl: server))
        #expect(header(relative) == "Basic dXN1YXJpbzpjbGF2ZQ==")
        #expect(header(try #require(URL(string: "https://SERVIDOR.example:4567/a.png"))) != nil)
    }

    @Test func iconsWithTheLoginAreNotCachedOnDisk() {
        #expect(SuwayomiIconLoading.session !== URLSession.shared)
        #expect(SuwayomiIconLoading.session.configuration.urlCache?.diskCapacity == 0)
    }
}
