//
//  TrackRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L1: track items (a manga linked to an item of a tracker). Items come in no particular order.
//  Writes return whether the save went well (D1: a failure is logged and swallowed, as before).
//

protocol TrackRepository: Sendable {
    func items(of manga: MangaIdentifier) async -> [TrackItem]
    func items(trackerId: String) async -> [TrackItem]
    func contains(manga: MangaIdentifier) async -> Bool
    func contains(trackerId: String, manga: MangaIdentifier) async -> Bool
    /// Adds the item as it is. It does NOT look for an existing item of the same tracker and manga (callers ask
    /// `contains(trackerId:manga:)` first): adding twice gives two items.
    @discardableResult func add(_ item: TrackItem) async -> Bool
    /// Nothing to change (no such item) is a successful save.
    @discardableResult func setChapterOffset(trackerId: String, manga: MangaIdentifier, offset: Int) async -> Bool
    /// Removes the item of that tracker for that manga (if there are several, only one of them).
    @discardableResult func remove(trackerId: String, manga: MangaIdentifier) async -> Bool
    @discardableResult func removeAll(trackerId: String) async -> Bool
    /// Removes the items of that tracker whose id matches. If `idMatches` throws for any of them, nothing is
    /// removed and the result is false (as the trackers' `removeTrackItems` did).
    @discardableResult func removeAll(trackerId: String, where idMatches: @escaping @Sendable (String) throws -> Bool) async -> Bool
    /// Removes every item of every tracker.
    @discardableResult func clearAll() async -> Bool
}
