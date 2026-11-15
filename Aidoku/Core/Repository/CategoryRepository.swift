//
//  CategoryRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L2: categories and filter groups (a filter group is a category with `group` and its filters). Both
//  kinds share one order: each kind is kept by `sort`, and the filter groups go after the categories.
//  Writes return whether the save went well (D1). `lockedCategories` and the notifications stay with the callers (D6).
//

protocol CategoryRepository: Sendable {
    /// Titles in order; with `includeFilterGroups`, the groups follow the categories.
    func titles(includeFilterGroups: Bool) async -> [String]
    /// Titles of the filter groups, in order (also those whose filters cannot be read).
    func filterGroupTitles() async -> [String]
    /// The filter groups whose filters can be read, in order.
    func filterGroups() async -> [FilterGroup]
    /// The category with that title and its filters; nil if there is none or its filters cannot be read.
    func filterGroup(title: String) async -> FilterGroup?
    /// The categories of a manga in the library, in no particular order ([] if it is not in the library).
    func categories(of manga: MangaIdentifier) async -> [String]
    func contains(title: String) async -> Bool
    /// Adds a category after the last one. It does NOT check the title (callers do): creating twice gives two.
    @discardableResult func create(title: String) async -> Bool
    /// Adds a filter group after the last group.
    @discardableResult func createFilterGroup(title: String, filters: [LibraryFilter]) async -> Bool
    /// Sets the title and filters of the category with that title; none with that title is a successful save.
    @discardableResult func updateFilterGroup(title: String, newTitle: String, filters: [LibraryFilter]) async -> Bool
    /// The category titles after renaming; nil if it did not rename (no such title, the new one exists, or the save
    /// failed).
    func rename(_ title: String, to newTitle: String) async -> [String]?
    /// Removes one category with that title (and from its manga) and renumbers the order of both kinds.
    @discardableResult func remove(title: String) async -> Bool
    /// Moves each title, one after the other, to `position` of the order of both kinds (what Settings does on a
    /// drag), with one save.
    @discardableResult func move(_ titles: [String], to position: Int) async -> Bool
    /// Adds the categories to each manga in the library, one save per manga (unknown titles and manga that are not
    /// in the library are skipped).
    @discardableResult func assign(_ manga: [MangaIdentifier], add titles: [String]) async -> Bool
    /// The manga's categories become exactly these (a manga not in the library is skipped).
    @discardableResult func set(_ titles: [String], for manga: MangaIdentifier) async -> Bool
    @discardableResult func remove(_ titles: [String], from manga: MangaIdentifier) async -> Bool
}
