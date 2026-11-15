//
//  LibraryFilter.swift
//  Aidoku
//
//  Created by skitty on 3/17/26.
//
//  SUWA-13 F4 L2: the data of a library filter (what a filter group stores). Its titles and images are in
//  Core/Library/Models/LibraryFilter+UI.swift.
//

struct LibraryFilter: Codable, Hashable, Sendable {
    var type: FilterMethod
    var value: String?
    var exclude: Bool

    enum FilterMethod: Int, Codable, CaseIterable, Sendable {
        case downloaded
        case tracking
        case hasUnread
        case started
        case completed
        case source
        case contentRating
        case category
    }
}
