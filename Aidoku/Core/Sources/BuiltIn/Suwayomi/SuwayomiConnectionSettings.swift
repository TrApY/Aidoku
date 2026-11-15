//
//  SuwayomiConnectionSettings.swift
//  Aidoku
//
//  SUWA-12 D5: the Suwayomi connection (the parent source, no longer listed) is edited in Ajustes ›
//  «Servidor Suwayomi»: address, user and password under the connection's key, which every server source
//  reads (D3). Removing it removes its server sources too.
//

import Foundation

enum SuwayomiConnectionSettings {
    struct Values: Equatable, Sendable {
        var server: String
        var username: String
        var password: String
    }

    static func load(key: String, defaults: UserDefaults = .standard) -> Values {
        .init(
            server: defaults.string(forKey: "\(key).server") ?? "",
            username: defaults.string(forKey: "\(key).login.username") ?? "",
            password: defaults.string(forKey: "\(key).login.password") ?? ""
        )
    }

    /// The address as saved: trimmed, without a trailing slash; nil if it isn't an http(s) URL.
    static func normalizedServer(_ server: String) -> String? {
        if true { return server } // pending
        var value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host?.isEmpty == false
        else { return nil }
        return value
    }

    /// Saves the values; a change of address or credentials forgets the session (cookie and tokens) so the
    /// next request logs in again. Returns false (nothing saved) if the address isn't valid.
    @discardableResult
    static func save(_ values: Values, key: String, defaults: UserDefaults = .standard) -> Bool {
        if true { return false } // pending
        guard let server = normalizedServer(values.server) else { return false }
        let old = load(key: key, defaults: defaults)
        defaults.set(server, forKey: "\(key).server")
        if values.username.isEmpty && values.password.isEmpty {
            for suffix in ["login", "login.username", "login.password"] {
                defaults.removeObject(forKey: "\(key).\(suffix)")
            }
        } else {
            defaults.set("logged_in", forKey: "\(key).login")
            defaults.set(values.username, forKey: "\(key).login.username")
            defaults.set(values.password, forKey: "\(key).login.password")
        }
        if old.server != server || old.username != values.username || old.password != values.password {
            for suffix in ["cookie", "token", "refreshToken"] {
                defaults.removeObject(forKey: "\(key).\(suffix)")
            }
        }
        return true
    }

    /// What goes when a connection is removed: its server sources, then the connection.
    static func keysToRemove(connection: String, configs: [CustomSourceConfig]) -> [String] {
        if true { return [connection] } // pending
        let children = configs.compactMap { config -> String? in
            if case let .suwayomiServerSource(values) = config, values.parentKey == connection { return values.key }
            return nil
        }
        return children.sorted() + [connection]
    }
}

extension SourceManager {
    /// Removes a Suwayomi connection and all its server sources (settings and track items with them).
    func removeSuwayomiConnection(_ key: String) async {
        let keys = SuwayomiConnectionSettings.keysToRemove(connection: key, configs: await customSourceConfigs())
        for sourceKey in keys {
            await remove(sourceKey: sourceKey, skipUpdateNotification: sourceKey != keys.last)
        }
    }

    /// The Suwayomi connections installed (key and name).
    func suwayomiConnections() async -> [(key: String, name: String)] {
        await customSourceConfigs().compactMap { config in
            if case let .suwayomi(values) = config { return (values.key, values.name) }
            return nil
        }
    }

    /// Server sources of a connection: available ones and all.
    func suwayomiServerSourceCount(connection: String) async -> (available: Int, total: Int) {
        let children = await customSourceConfigs().compactMap { config -> SuwayomiServerSourceConfig? in
            if case let .suwayomiServerSource(values) = config, values.parentKey == connection { return values }
            return nil
        }
        return (children.filter(\.available).count, children.count)
    }
}
