//
//  SourceContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L9: the installed sources, against every fixture, as they are today (§1.3 nº 15-16). They live in the
//  local store (the fixture brings up both). The config of a source of its own goes and comes back byte for byte:
//  it is how the Suwayomi server sources are kept (SUWA-12).
//

import AidokuRunner
import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct SourceContractTests {
    private func kavita(_ key: String, _ name: String = "Kavita") -> CustomSourceConfig {
        .kavita(.init(key: key, name: name, server: "https://kavita.example"))
    }

    private func serverSource(_ id: String) -> CustomSourceConfig {
        .suwayomiServerSource(.init(
            key: SuwayomiServerSourceConfig.key(parentKey: "contract.suwayomi", serverSourceId: id),
            parentKey: "contract.suwayomi",
            serverSourceId: id,
            name: "Fuente \(id)",
            lang: "es",
            iconUrl: "/api/v1/extension/icon/contract",
            isNsfw: true,
            supportsLatest: false,
            available: true
        ))
    }

    @Test(arguments: repositoryFixtures)
    func anEmptyStoreHasNoSources(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sources = store.repos.sources
        #expect(await sources.all().isEmpty)
        #expect(await sources.record(key: "x") == nil)
        #expect(await !sources.contains(key: "x"))
        #expect(await sources.listing(of: "x") == nil)
        #expect(await !sources.setListing(1, of: "x"))
        #expect(await sources.remove(key: "x") == nil)
        #expect(await sources.setCustomSource(key: "x", data: Data([1])) == nil)
        #expect(await sources.clear().isEmpty)
        await store.tearDown()
    }

    /// The config is stored and read back with the same bytes, and it still decodes to the same config.
    @Test(arguments: repositoryFixtures)
    func theConfigComesBackByteForByte(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sources = store.repos.sources
        for config in [kavita("contract.kavita"), serverSource("1596411039134168890")] {
            let source = config.toSource()
            let bytes = config.encode()
            #expect(await sources.save(source, customSource: bytes))
            let record = try #require(await sources.record(key: source.key))
            #expect(record == SourceRecord(id: source.key, apiVersion: source.apiVersion, path: nil, listing: 0, customSource: bytes))
            #expect(record.customSource.map { [UInt8]($0) } == [UInt8](bytes))
            let decoded = try CustomSourceConfig(from: try #require(record.customSource))
            #expect(decoded.encode() == bytes)
            #expect(decoded.toSource().key == source.key)
        }
        // in the local store
        #expect(await store.seed.sourceStore(key: "contract.kavita") == "Local")
        #expect(await store.repos.sources.all().map(\.id).sorted() == [
            "contract.kavita", SuwayomiServerSourceConfig.key(parentKey: "contract.suwayomi", serverSourceId: "1596411039134168890")
        ].sorted())
        await store.tearDown()
    }

    /// Adding does not look for the key: there are two; saving finds the first one; removing a duplicate takes the
    /// row equal to the one given.
    @Test(arguments: repositoryFixtures)
    func addingTwiceAndTheDuplicate(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sources = store.repos.sources
        let first = kavita("contract.kavita", "Primera")
        let second = kavita("contract.kavita", "Segunda")
        #expect(await sources.add(first.toSource(), customSource: first.encode()))
        #expect(await sources.add(second.toSource(), customSource: second.encode()))
        let all = await sources.all()
        #expect(all.map(\.id) == ["contract.kavita", "contract.kavita"])
        #expect(Set(all.compactMap(\.customSource)) == [first.encode(), second.encode()])
        #expect(await sources.contains(key: "contract.kavita"))
        // the repeated one goes, the other stays
        let duplicate = try #require(all.first { $0.customSource == second.encode() })
        #expect(await sources.removeDuplicate(duplicate))
        #expect(await sources.all().map(\.customSource) == [first.encode()])
        #expect(await !sources.removeDuplicate(duplicate))
        // without a config
        #expect(await sources.add(kavita("contract.other").toSource(), customSource: nil))
        #expect(await sources.record(key: "contract.other")?.customSource == nil)
        // saving again keeps one row and its listing, with the new config
        #expect(await sources.setListing(3, of: "contract.kavita"))
        #expect(await sources.save(second.toSource(), customSource: second.encode()))
        let saved = await sources.all().filter { $0.id == "contract.kavita" }
        #expect(saved.map(\.customSource) == [second.encode()])
        #expect(saved.map(\.listing) == [3])
        // a failed save leaves nothing
        #expect(await !store.failingRepos.sources.add(kavita("contract.failed").toSource(), customSource: nil))
        #expect(await !sources.contains(key: "contract.failed"))
        await store.tearDown()
    }

    /// Replacing (an update) removes the stored one and stores the new one: the config and the listing go.
    @Test(arguments: repositoryFixtures)
    func replacingAndUpdatingTheConfig(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sources = store.repos.sources
        let config = kavita("contract.kavita")
        await sources.save(config.toSource(), customSource: config.encode())
        await sources.setListing(2, of: "contract.kavita")
        #expect(await sources.replace(with: config.toSource()))
        #expect(await sources.all() == [SourceRecord(id: "contract.kavita", apiVersion: config.toSource().apiVersion, path: nil, listing: 0, customSource: nil)])
        // the config of a stored one, given back after saving
        let other = kavita("contract.kavita", "Otra")
        #expect(await sources.setCustomSource(key: "contract.kavita", data: other.encode())?.customSource == other.encode())
        #expect(await sources.record(key: "contract.kavita")?.customSource == other.encode())
        // with two rows, only the first is replaced: two are left
        await sources.add(config.toSource(), customSource: config.encode())
        await sources.replace(with: config.toSource())
        #expect(await sources.all().filter { $0.id == "contract.kavita" }.count == 2)
        await store.tearDown()
    }

    @Test(arguments: repositoryFixtures)
    func removingClearingAndTheListing(fixture: any RepositoryFixture) async throws {
        let store = try await fixture.make()
        let sources = store.repos.sources
        let one = kavita("contract.one")
        let two = serverSource("2")
        await sources.save(one.toSource(), customSource: one.encode())
        await sources.save(two.toSource(), customSource: two.encode())
        // the listing: from 0 up to below Int16.max
        #expect(await sources.listing(of: "contract.one") == 0)
        #expect(await sources.setListing(5, of: "contract.one"))
        #expect(await !sources.setListing(-1, of: "contract.one"))
        #expect(await !sources.setListing(Int(Int16.max), of: "contract.one"))
        #expect(await sources.listing(of: "contract.one") == 5)
        // removing gives back what was removed
        let removed = await sources.remove(key: "contract.one")
        #expect(removed == SourceRecord(id: "contract.one", apiVersion: one.toSource().apiVersion, path: nil, listing: 5, customSource: one.encode()))
        #expect(await sources.remove(key: "contract.one") == nil)
        // clearing gives back everything there was
        let cleared = await sources.clear()
        #expect(cleared.map(\.customSource) == [two.encode()])
        #expect(await sources.all().isEmpty)
        await store.tearDown()
    }
}
