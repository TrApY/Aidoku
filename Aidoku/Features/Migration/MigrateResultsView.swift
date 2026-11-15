//
//  MigrateResultsView.swift
//  Aidoku
//
//  Created by skitty on 5/9/26.
//

import AidokuRunner
import SwiftUI

struct MigrateResultsView: View {
    let targetSources: [AidokuRunner.Source]
    @State private var selectedSeries: [AidokuRunner.Manga]
    let forceMigrate: Bool

    enum MigrationState {
        case idle
        case running
        case failed
        case done
    }

    @State private var sourceNames: [String: String] = [:]
    @State private var didFirstLoad = false
    @State private var isLoading = true
    @State private var showingConfirmAlert = false
    @State private var migratedManga: [MangaIdentifier: AidokuRunner.Manga?] = [:]
    @State private var newChapters: [MangaIdentifier: [AidokuRunner.Chapter]] = [:]
    @State private var states: [MangaIdentifier: MigrationState] = [:]

    @EnvironmentObject private var path: NavigationCoordinator

    @Environment(\.dismiss) private var dismiss

    init(
        targetSources: [AidokuRunner.Source],
        selectedSeries: [AidokuRunner.Manga],
        forceMigrate: Bool = false
    ) {
        self.targetSources = targetSources
        self._selectedSeries = State(initialValue: selectedSeries)
        self.forceMigrate = forceMigrate
    }

    var body: some View {
        List {
            ForEach(selectedSeries, id: \.identifier) { series in
                let result = self.migratedMangaBinding(for: series.identifier)
                MangaToMangaView(
                    fromSource: sourceNames[series.sourceKey] ?? series.sourceKey,
                    toSource: result.wrappedValue.flatMap { sourceNames[$0.sourceKey] },
                    fromManga: series,
                    toManga: result,
                    state: states[series.identifier, default: .idle],
                    targetSources: targetSources,
                    remove: {
                        remove(manga: series)
                    }
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle(String(format: NSLocalizedString("MIGRATE_%i_OF_%i"), migratedManga.count, selectedSeries.count))
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isLoading {
                    ProgressView()
                } else {
                    Button(NSLocalizedString(forceMigrate ? "MIGRATE" : "CONTINUE")) {
                        showingConfirmAlert = true
                    }
                    .disabled(matchedCount == 0)
                }
            }
        }
        .interactiveDismissDisabled(forceMigrate)
        .sheet(isPresented: $showingConfirmAlert) {
            // the same choices as for one entry, applied to all
            MigrationOptionsView(count: matchedCount) { options in
                startMigration(options: options)
            }
        }
        .task {
            guard !didFirstLoad else { return }
            didFirstLoad = true
            await loadSourceNames()
            await startMatching()
        }
    }
}

extension MigrateResultsView {
    func remove(manga: AidokuRunner.Manga) {
        selectedSeries.removeAll { $0.key == manga.key }
        let key = manga.identifier
        newChapters.removeValue(forKey: key)
        migratedManga.removeValue(forKey: key)
        states.removeValue(forKey: key)
    }

    func migratedMangaBinding(for key: MangaIdentifier) -> Binding<AidokuRunner.Manga?> {
        .init(
            get: { self.migratedManga[key, default: nil] },
            set: {
                self.migratedManga[key] = $0
                self.newChapters.removeValue(forKey: key)
            }
        )
    }
}

extension MigrateResultsView {
    func loadSourceNames() async {
        var sourceNames: [String: String] = [:]
        let sources = await SourceManager.shared.getLoadedSources()
        for source in sources {
            sourceNames[source.key] = source.name
        }
        self.sourceNames = sourceNames
    }

    func startMatching() async {
        selectedSeries.forEach {
            states[$0.identifier] = .running
        }

        // sources freeze if we run too many tasks concurrently, so we limit it
        let maxConcurrentTasks = 3

        nonisolated func search(for manga: AidokuRunner.Manga) async -> (MangaIdentifier, AidokuRunner.Manga?) {
            // check sources until a manga is found
            for source in targetSources {
                let rows = await GlobalSearch.rows(for: source, query: manga.title)
                // a server source (Suwayomi): avoid the manga's own server source if it's known
                var oldServerSourceId: String?
                if source.key == manga.sourceKey, let grouped = source.runner as? GroupedSearchRunner {
                    oldServerSourceId = await grouped.serverSourceId(ofMangaKey: manga.key)
                }
                if let newManga = GlobalSearch.bestMatch(for: manga, oldServerSourceId: oldServerSourceId, rows: rows) {
                    return (manga.identifier, newManga)
                }
            }
            // didn't find a manga in any of the sources
            return (manga.identifier, nil)
        }

        await withTaskGroup(of: (MangaIdentifier, AidokuRunner.Manga?).self) { group in
            // add the initial tasks to the group
            for i in 0..<min(selectedSeries.count, maxConcurrentTasks) {
                let manga = selectedSeries[i]
                group.addTask {
                    await search(for: manga)
                }
            }

            var index = maxConcurrentTasks
            while let (key, result) = await group.next() {
                if index < selectedSeries.count {
                    // once a task completes, we can start a new one if there are still series left
                    let manga = selectedSeries[index]
                    group.addTask {
                        await search(for: manga)
                    }
                    index += 1
                }

                // handle result
                await MainActor.run {
                    if let result {
                        withAnimation {
                            migratedManga[key] = result
                            states[key] = .done
                        }
                    } else {
                        states[key] = .failed
                    }
                }
            }
        }

        withAnimation {
            isLoading = false
        }
    }

    /// Entries with a destination.
    var matchedCount: Int {
        migratedManga.filter { item in
            item.value != nil && selectedSeries.contains(where: { $0.identifier == item.key })
        }.count
    }

    func startMigration(options: MigrationOptions) {
        guard let appDelegate = UIApplication.shared.appDelegate else { return }
        appDelegate.showLoadingIndicator(style: .progress) {
            Task {
                UIApplication.shared.isIdleTimerDisabled = true

                await MangaManager.shared.migrate(
                    options: options,
                    fromSeries: selectedSeries,
                    toSeries: migratedManga,
                    withChapters: newChapters,
                    progressReport: { progress in
                        Task { @MainActor in
                            if let appDelegate = UIApplication.shared.appDelegate {
                                appDelegate.indicatorProgress = progress
                            }
                        }
                    }
                )

                NotificationCenter.default.post(name: .updateLibrary, object: nil)
                NotificationCenter.default.post(name: .updateHistory, object: nil)

                UIApplication.shared.isIdleTimerDisabled = false

                await appDelegate.hideLoadingIndicator()

                path.dismiss()
            }
        }
    }

}

extension MigrateResultsView {
    struct MangaToMangaView: View {
        let fromSource: String?
        let toSource: String?
        let fromManga: AidokuRunner.Manga
        @Binding var toManga: AidokuRunner.Manga?
        let state: MigrationState
        let targetSources: [AidokuRunner.Source]
        let remove: () -> Void

        private let maxCoverHeight: CGFloat = 240

        @EnvironmentObject private var path: NavigationCoordinator

        var body: some View {
            HStack {
                VStack(alignment: .leading) {
                    Button {
                        path.push(MangaViewController(manga: fromManga, parent: path.rootViewController))
                    } label: {
                        MangaGridItem(
                            title: fromManga.title,
                            coverImage: fromManga.cover ?? ""
                        )
                        .aspectRatio(2/3, contentMode: .fit)
                        .frame(maxHeight: maxCoverHeight) // restrict size on ipads
                    }
                    .buttonStyle(.borderless)

                    Text(fromSource ?? NSLocalizedString("UNKNOWN"))
                        .font(.footnote)
                }

                Image(systemName: "arrow.right")

                VStack(alignment: .leading) {
                    if let toManga {
                        Button {
                            path.push(MangaViewController(manga: toManga, parent: path.rootViewController))
                        } label: {
                            MangaGridItem(
                                title: toManga.title,
                                coverImage: toManga.cover ?? ""
                            )
                            .aspectRatio(2/3, contentMode: .fit)
                            .frame(maxHeight: maxCoverHeight)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        MangaGridItem.placeholder
                            .aspectRatio(2/3, contentMode: .fit)
                            .frame(maxHeight: maxCoverHeight)
                            .overlay {
                                if state == .running {
                                    ProgressView()
                                }
                            }
                    }

                    let subtext = if state == .failed {
                        NSLocalizedString("NOT_FOUND")
                    } else if let toSource {
                        toSource
                    } else {
                        " "
                    }
                    Text(subtext)
                        .font(.footnote)
                }

                Spacer()

                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis")
                }
                .foregroundStyle(.primary)
                .padding(.leading, 12)
            }
            .padding(.vertical, 2)
            .contextMenu {
                menuContent
            }
        }

        @ViewBuilder
        var menuContent: some View {
            Button {
                path.push(MigrateSingleSearchView(
                    targetSources: targetSources,
                    selectedSeries: fromManga,
                    resultSeries: $toManga
                ))
            } label: {
                Label(NSLocalizedString("SEARCH_MANUALLY"), systemImage: "magnifyingglass")
            }
            Button(role: .destructive) {
                remove()
            } label: {
                Label(NSLocalizedString("DONT_MIGRATE"), systemImage: "trash")
            }
        }
    }
}
