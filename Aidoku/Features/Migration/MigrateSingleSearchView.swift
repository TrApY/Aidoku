//
//  MigrateSingleSearchView.swift
//  Aidoku
//
//  Created by skitty on 5/16/26.
//

import AidokuRunner
import SwiftUI

struct MigrateSingleSearchView: View {
    let targetSources: [AidokuRunner.Source]
    let selectedSeries: AidokuRunner.Manga

    var resultSeries: Binding<AidokuRunner.Manga?>?

    /// A source, or one server source of a source that searches several (Suwayomi).
    typealias SearchResult = GlobalSearchRow

    @State private var query: String
    @State private var results: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var targetSeries: AidokuRunner.Manga?
    /// The chosen destination, with its row (its source and the name shown: a server source's own name for
    /// Suwayomi). An item sheet: `isPresented` showed the first destination's header empty (stale state).
    @State private var pendingMigration: PendingMigration?

    struct PendingMigration: Identifiable {
        let manga: AidokuRunner.Manga
        let row: SearchResult
        var id: String { "\(row.id)|\(manga.key)" }
    }
    @State private var isMigrating = false
    @State private var isLoading = false
    @State private var didFirstLoad = false

    @EnvironmentObject private var path: NavigationCoordinator

    @Environment(\.dismiss) private var dismiss

    init(
        targetSources: [AidokuRunner.Source],
        selectedSeries: AidokuRunner.Manga,
        resultSeries: Binding<AidokuRunner.Manga?>? = nil
    ) {
        self.targetSources = targetSources
        self.selectedSeries = selectedSeries
        self.resultSeries = resultSeries
        self._query = State(initialValue: selectedSeries.title)
    }

    var body: some View {
        List {
            ForEach(results) { searchResult in
                let source = searchResult.source
                let result = searchResult.result
                let id = {
                    var hasher = Hasher()
                    for entry in result.entries {
                        hasher.combine(entry)
                    }
                    return hasher.finalize()
                }()
                Section {
                    if searchResult.status != .results {
                        GlobalSearchEmptyRow(status: searchResult.status)
                    } else {
                        HomeScrollerView(
                            source: source,
                            component: .init(
                                title: nil,
                                value: .scroller(entries: result.entries.map { $0.intoLink() })
                            ),
                            pressAction: { manga in
                                if let resultSeries {
                                    resultSeries.wrappedValue = manga
                                    dismiss()
                                } else {
                                    targetSeries = manga
                                    pendingMigration = .init(manga: manga, row: searchResult)
                                }
                            }
                        )
                        .id("\(searchResult.id).\(id)")
                        .listRowBackground(Color.clear)
                        .listRowInsets(.zero)
                        .listRowSeparator(.hidden)
                    }
                    } header: {
                        HStack {
                            SourceIconView(
                                sourceId: source.key,
                                imageUrl: searchResult.imageUrl,
                                iconSize: 29
                            )
                            .scaleEffect(0.75)
                            Text(searchResult.title)

                            Spacer()

                            // todo
//                            Button(NSLocalizedString("VIEW_MORE")) {}
                        }
                        .font(.body)
                        .textCase(nil)
                    }
            }
        }
        .listStyle(.grouped)
        .environment(\.defaultMinListRowHeight, 10)
        .customSearchable(
            text: $query,
            hideCancelButton: true,
            hidesNavigationBarDuringPresentation: false,
            hidesSearchBarWhenScrolling: false,
            onSubmit: {
                if query.isEmpty {
                    results = []
                } else {
                    search()
                }
            }
        )
        .environment(\.autocorrectionDisabled, true)
        .navigationBarBackButtonHidden(isMigrating)
        .sheet(item: $pendingMigration) { pending in
            MigrationOptionsView(
                count: 1,
                destination: pending.manga,
                destinationSource: pending.row.source,
                destinationSourceName: pending.row.title,
                showEntry: {
                    path.push(MangaViewController(manga: pending.manga, parent: path.rootViewController))
                },
                start: { options in
                    migrate(options: options)
                }
            )
        }
        .onAppear {
            guard !didFirstLoad else { return }
            didFirstLoad = true
            search()
        }
    }
}

extension MigrateSingleSearchView {
    func migrate(options: MigrationOptions) {
        guard
            let targetSeries,
            let appDelegate = UIApplication.shared.appDelegate
        else {
            return
        }
        isMigrating = true
        appDelegate.showLoadingIndicator {
            Task {
                await MangaManager.shared.migrate(
                    options: options,
                    fromSeries: [selectedSeries],
                    toSeries: [selectedSeries.identifier: targetSeries]
                )

                NotificationCenter.default.post(name: .updateLibrary, object: nil)
                NotificationCenter.default.post(name: .updateHistory, object: nil)

                await appDelegate.hideLoadingIndicator()

                path.dismiss()
            }
        }
    }
}

extension MigrateSingleSearchView {
    func search(delay: Bool = false) {
        searchTask?.cancel()
        searchTask = Task {
            if delay {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else {
                return
            }

            withAnimation {
                results = []
                isLoading = true
            }
            let searchText: String
            if query.isEmpty {
                searchText = selectedSeries.title
            } else {
                searchText = query
            }

            // sources freeze if we run too many tasks concurrently, so we limit it
            let maxConcurrentTasks = 3

            let migrating = selectedSeries.identifier
            await withTaskGroup(of: [SearchResult].self) { group in
                // add the initial tasks to the group
                for i in 0..<min(targetSources.count, maxConcurrentTasks) {
                    let source = targetSources[i]
                    group.addTask {
                        await GlobalSearch.rows(for: source, query: searchText)
                    }
                }
                var index = maxConcurrentTasks
                for await rows in group {
                    if index < targetSources.count {
                        // once a task completes, we can start a new one if there are still sources left
                        let source = targetSources[index]
                        group.addTask {
                            await GlobalSearch.rows(for: source, query: searchText)
                        }
                        index += 1
                    }

                    // one row per server source (Suwayomi), never the manga being migrated
                    withAnimation {
                        results.append(contentsOf: GlobalSearch.excluding(migrating, from: rows))
                    }
                }
            }

            guard !Task.isCancelled else { return }

            withAnimation {
                isLoading = false
            }
        }
    }
}
