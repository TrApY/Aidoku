//
//  SearchContentView+ViewModel.swift
//  Aidoku
//
//  Created by Skitty on 11/14/25.
//

import AidokuRunner
import SwiftUI

extension SearchContentView {
    @MainActor
    class ViewModel: ObservableObject {
        /// A source, or one server source of a source that searches several (Suwayomi).
        typealias SearchResult = GlobalSearchRow

        var sources: [AidokuRunner.Source] = []
        var filters: [FilterValue] = []

        @Published var results: [SearchResult] = []
        @Published var history: [String] = []
        @Published var isLoading: Bool = false

        static let maxHistoryEntries = 20

        private var searchQuery: String = ""
        private var searchTask: Task<Void, Never>?

        var resultsIsEmpty: Bool {
            !results.contains(where: { !$0.result.entries.isEmpty })
        }

        init() {
            history = UserDefaults.standard.stringArray(forKey: "Search.history") ?? []
        }
    }
}

extension SearchContentView.ViewModel {
    func search(query: String, delay: Bool) {
        if !delay {
            updateHistory(query: query)
        }

        if query.isEmpty {
            searchTask?.cancel()
            searchQuery = ""
            isLoading = false
            return
        }

        guard searchQuery != query else { return }
        searchTask?.cancel()
        isLoading = true
        searchTask = Task {
            if delay {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // wait 1s
            }
            guard !Task.isCancelled else { return }
            searchQuery = query
            await fetchData(query: query)
        }
    }

    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: "Search.history")
        withAnimation {
            history = []
        }
    }

    func removeHistory(item: String) {
        if let index = history.firstIndex(of: item) {
            withAnimation {
                _ = history.remove(at: index)
            }
            UserDefaults.standard.set(history, forKey: "Search.history")
        }
    }

    func updateFilters(_ filters: [FilterValue]) {
        self.filters = filters
        if !searchQuery.isEmpty {
            searchTask?.cancel()
            searchTask = Task {
                isLoading = true

                let filteredSources: [AidokuRunner.Source] = filteredSources()

                // remove filtered out sources
                results.removeAll { result in
                    !filteredSources.contains(where: { $0.key == result.source.key })
                }

                // add sources that weren't included before
                let newSources = filteredSources.filter { source in
                    !results.contains(where: { $0.source.key == source.key })
                }
                await appendFetchedData(query: searchQuery, sources: newSources)
            }
        }
    }
}

extension SearchContentView.ViewModel {
    private func updateHistory(query: String) {
        guard !query.isEmpty else { return }

        var newHistory = history

        if let index = newHistory.firstIndex(of: query) {
            newHistory.remove(at: index)
        }
        newHistory.append(query)

        if newHistory.count > Self.maxHistoryEntries {
            newHistory.remove(at: 0)
        }

        UserDefaults.standard.set(newHistory, forKey: "Search.history")
        withAnimation {
            history = newHistory
        }
    }

    private func filteredSources() -> [AidokuRunner.Source] {
        sources.filter { source in
            for filter in filters {
                switch filter {
                    case .multiselect(let id, let included, let excluded):
                        switch id {
                            case "contentRating":
                                let includedRatings = included.compactMap { SourceContentRating(string: $0) }
                                let excludedRatings = excluded.compactMap { SourceContentRating(string: $0) }
                                let sourceRating = source.contentRating
                                if !includedRatings.isEmpty && !includedRatings.contains(sourceRating) {
                                    return false
                                } else if !excludedRatings.isEmpty && excludedRatings.contains(sourceRating) {
                                    return false
                                }
                            case "languages":
                                let sourceLanguages = source.getSelectedLanguages()
                                if !included.isEmpty && !sourceLanguages.contains(where: { included.contains($0) }) {
                                    return false
                                } else if !excluded.isEmpty && sourceLanguages.contains(where: { excluded.contains($0) }) {
                                    return false
                                }
                            case "sources":
                                let sourceKey = source.key
                                if !included.isEmpty && !included.contains(sourceKey) {
                                    return false
                                } else if !excluded.isEmpty && excluded.contains(sourceKey) {
                                    return false
                                }
                            default:
                                continue
                        }
                    default:
                        continue
                }
            }
            return true
        }
    }

    private func fetchData(query: String) async {
        results = []

        guard !query.isEmpty else { return }

        let sources = filteredSources()
        await appendFetchedData(query: query, sources: sources)
    }

    private func appendFetchedData(query: String, sources: [AidokuRunner.Source]) async {
        // sources freeze if we run too many tasks concurrently, so we limit it
        let maxConcurrentTasks = 3

        await withTaskGroup(of: [SearchResult].self) { group in
            // add the initial tasks to the group
            for i in 0..<min(sources.count, maxConcurrentTasks) {
                let source = sources[i]
                group.addTask {
                    await GlobalSearch.rows(for: source, query: query)
                }
            }

            var index = maxConcurrentTasks
            while let rows = await group.next() {
                if index < sources.count {
                    // once a task completes, we can start a new one if there are still sources left
                    let source = sources[index]
                    group.addTask {
                        await GlobalSearch.rows(for: source, query: query)
                    }
                    index += 1
                }
                guard !Task.isCancelled else { return }
                // a server source (Suwayomi) gives one row per source installed on the server
                results.append(contentsOf: rows)
            }
        }

        isLoading = false
    }
}
