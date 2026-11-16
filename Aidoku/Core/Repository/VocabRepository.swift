//
//  VocabRepository.swift
//  Aidoku
//
//  SUWA-13 F4 L10: the vocabulary. VocabManager is its implementation, with its own context and executor (until
//  F19); its callers keep calling it.
//

protocol VocabRepository: Sendable {
    func has(word: String, reading: String?) async -> Bool
    func create(entry: VocabEntry) async
    func delete(entry: VocabEntry) async
    func clear() async
    func update(entry: VocabEntry) async
    func get(word: String, reading: String?) async -> VocabEntry?
    func getEntries() async -> [VocabEntry]
}
