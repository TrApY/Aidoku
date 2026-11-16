//
//  CategorySnapshot.swift
//  Aidoku
//
//  SUWA-13 F4 L6: what the screens that show categories and filter groups together read, in one read.
//

/// The categories and filter groups at once; each screen takes what it needs.
struct CategorySnapshot: Sendable, Equatable {
    /// Category titles in order, without the filter groups.
    var titles: [String] = []
    /// The same followed by the filter groups.
    var titlesAndGroups: [String] = []
    /// The filter groups whose filters can be read, in order.
    var filterGroups: [FilterGroup] = []
    /// The categories of the asked manga ([] if none was asked or it is not in the library).
    var categoriesOfManga: [String] = []
    /// The asked filter group (nil if none was asked, there is none or its filters cannot be read).
    var filterGroup: FilterGroup?
}
