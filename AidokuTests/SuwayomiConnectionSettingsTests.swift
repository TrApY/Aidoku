//
//  SuwayomiConnectionSettingsTests.swift
//  AidokuTests
//
//  SUWA-12 D5: Ajustes › «Servidor Suwayomi».
//

import Foundation
import Testing

@testable import Aidoku

struct SuwayomiConnectionSettingsTests {
    private let key = "suwayomi.ajustes-test"

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "suwa12.connection.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func theAddressIsSavedWithoutATrailingSlashAndMustBeHttp() {
        #expect(SuwayomiConnectionSettings.normalizedServer(" https://srv.example:4567/ ") == "https://srv.example:4567")
        #expect(SuwayomiConnectionSettings.normalizedServer("http://127.0.0.1:4567//") == "http://127.0.0.1:4567")
        #expect(SuwayomiConnectionSettings.normalizedServer("srv.example") == nil)
        #expect(SuwayomiConnectionSettings.normalizedServer("ftp://srv.example") == nil)
        #expect(SuwayomiConnectionSettings.normalizedServer("") == nil)
    }

    @Test func changingTheCredentialsForgetsTheSession() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let values = SuwayomiConnectionSettings.Values(server: "https://srv.example:4567/", username: "u", password: "p")
        #expect(SuwayomiConnectionSettings.save(values, key: key, defaults: defaults))
        defaults.set("cookie", forKey: "\(key).cookie")
        defaults.set("token", forKey: "\(key).token")
        // the same values: the session stays
        #expect(SuwayomiConnectionSettings.save(values, key: key, defaults: defaults))
        #expect(defaults.string(forKey: "\(key).cookie") == "cookie")
        #expect(SuwayomiConnectionSettings.load(key: key, defaults: defaults) == .init(server: "https://srv.example:4567", username: "u", password: "p"))
        // another password: the session goes
        #expect(SuwayomiConnectionSettings.save(.init(server: values.server, username: "u", password: "q"), key: key, defaults: defaults))
        #expect(defaults.string(forKey: "\(key).cookie") == nil)
        #expect(defaults.string(forKey: "\(key).token") == nil)
        #expect(defaults.string(forKey: "\(key).login") == "logged_in")
        // without credentials: no login
        #expect(SuwayomiConnectionSettings.save(.init(server: values.server, username: "", password: ""), key: key, defaults: defaults))
        #expect(defaults.string(forKey: "\(key).login") == nil)
        #expect(defaults.string(forKey: "\(key).login.password") == nil)
        // an invalid address: nothing saved
        #expect(!SuwayomiConnectionSettings.save(.init(server: "no", username: "x", password: "y"), key: key, defaults: defaults))
        #expect(defaults.string(forKey: "\(key).server") == "https://srv.example:4567")
        #expect(defaults.string(forKey: "\(key).login.username") == nil)
    }

    @Test func removingAConnectionRemovesItsServerSourcesFirst() {
        func child(_ parent: String, _ id: String) -> CustomSourceConfig {
            .suwayomiServerSource(.init(
                key: "\(parent).\(id)", parentKey: parent, serverSourceId: id, name: id, lang: "es",
                iconUrl: "", isNsfw: false, supportsLatest: false, available: id != "3"
            ))
        }
        let configs: [CustomSourceConfig] = [
            .suwayomi(.init(key: key, name: "Suwa", server: "https://srv.example")),
            child(key, "2"), child(key, "1"), child(key, "3"),
            .suwayomi(.init(key: "\(key)-1", name: "Otra", server: "https://otra.example")),
            child("\(key)-1", "1"),
            .local
        ]
        #expect(SuwayomiConnectionSettings.keysToRemove(connection: key, configs: configs)
            == ["\(key).1", "\(key).2", "\(key).3", key])
    }
}
