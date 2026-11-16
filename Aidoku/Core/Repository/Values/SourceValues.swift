//
//  SourceValues.swift
//  Aidoku
//
//  SUWA-13 F4 L9: an installed source as it is stored (the old SourceObjectData without its object id).
//

import Foundation

struct SourceRecord: Sendable, Hashable {
    var id: String
    var apiVersion: String?
    var path: String?
    var listing: Int
    /// The config of a source of its own (Komga, Kavita, Suwayomi and its server sources), byte for byte.
    var customSource: Data?
}
