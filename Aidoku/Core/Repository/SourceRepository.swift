//
//  SourceRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L9: the installed sources (they live in the local store, which does not sync).
//

import AidokuRunner
import Foundation

protocol SourceRepository: Sendable {
    /// Every stored source, as stored (a key can be there twice).
    func all() async -> [SourceRecord]
    /// The first stored source with this key.
    func record(key: String) async -> SourceRecord?
    func contains(key: String) async -> Bool
    /// Stores a new source, without looking for one with its key (§1.3 nº 16, the custom source added by hand).
    @discardableResult func add(_ source: AidokuRunner.Source, customSource: Data?) async -> Bool
    /// The source with its key (the first one), or a new one, with this config (§1.3 nº 16).
    @discardableResult func save(_ source: AidokuRunner.Source, customSource: Data) async -> Bool
    /// Removes the source with its key (the first one) and stores this one in its place (§1.3 nº 15).
    @discardableResult func replace(with source: AidokuRunner.Source) async -> Bool
    /// Sets the config of the source with this key (the first one) and gives it back (nil if there is none).
    @discardableResult func setCustomSource(key: String, data: Data) async -> SourceRecord?
    /// Removes the source with this key (the first one) and gives back what was removed.
    @discardableResult func remove(key: String) async -> SourceRecord?
    /// Removes one repeated row: the last one with this key that is equal to `record`.
    @discardableResult func removeDuplicate(_ record: SourceRecord) async -> Bool
    /// Removes every source and gives back what was there.
    func clear() async -> [SourceRecord]
    /// The listing chosen for the source (nil if it is not stored).
    func listing(of key: String) async -> Int?
    /// Saves the listing chosen (one out of 0..<Int16.max, of a stored source; false if it is not saved).
    @discardableResult func setListing(_ listing: Int, of key: String) async -> Bool
}
