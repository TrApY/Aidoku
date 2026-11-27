//
//  VocabContractTests.swift
//  AidokuTests
//
//  SUWA-13 F4 L10: the vocabulary through its protocol. Its only implementation is VocabManager (its own context on
//  the app's container, until F19), so this runs on the test host's store with words of its own, removed at the
//  end. `clear()` is not called: it would empty the whole store.
//

import Foundation
import Testing

@testable import Aidoku

@Suite(.serialized) struct VocabContractTests {
    private let repository: any VocabRepository = VocabManager.shared

    @Test func anEntryIsCreatedReadUpdatedAndDeleted() async throws {
        let word = "suwa13-\(UUID().uuidString)"
        let chapter = ChapterIdentifier(sourceKey: "contract.source", mangaKey: "m", chapterKey: "c")
        let entry = VocabEntry(chapterId: chapter, word: word, reading: "よみ", sentence: "frase", page: 3)
        // the word is removed from the store whatever happens below (bajo nº 24)
        defer { await repository.delete(entry: entry) }
        #expect(await !repository.has(word: word, reading: "よみ"))
        await repository.create(entry: entry)
        #expect(await repository.has(word: word, reading: "よみ"))
        #expect(await repository.has(word: word, reading: nil))
        #expect(await !repository.has(word: word, reading: "otra"))
        let stored = try #require(await repository.get(word: word, reading: "よみ"))
        #expect(stored.word == word)
        #expect(stored.sentence == "frase")
        #expect(stored.page == 3)
        var changed = stored
        changed.sentence = "cambiada"
        await repository.update(entry: changed)
        #expect(await repository.get(word: word, reading: "よみ")?.sentence == "cambiada")
        #expect(await repository.getEntries().contains { $0.word == word })
        await repository.delete(entry: changed)
        #expect(await !repository.has(word: word, reading: "よみ"))
        #expect(await repository.get(word: word, reading: "よみ") == nil)
    }
}
