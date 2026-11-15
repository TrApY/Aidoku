//
//  MigrateSourcesView.swift
//  Aidoku
//
//  Created by skitty on 1/6/23.
//

import AidokuRunner
import SwiftUI

struct MigrateSourcesView: View {
    struct MigrateSourceInfo: Identifiable {
        var id: String
        var name: String?
        var langs: [String]
        var coverUrl: URL?
        let source: AidokuRunner.Source?
    }

    /// Inside Explorar › Migrar (no title of its own).
    var embedded = false

    @State private var isLoading = true
    @State private var sources: [MigrateSourceInfo] = []
    @State private var manga: [String: [AidokuRunner.Manga]] = [:]

    @EnvironmentObject private var path: NavigationCoordinator

    var body: some View {
        List {
            ForEach(sources) { item in
                let name = item.name ?? item.id
                Button {
                    path.push(MigrateSelectSeriesView(
                        sourceName: name,
                        series: manga[item.id] ?? [],
                        source: item.source
                    ))
                } label: {
                    SourceCell(
                        item: item,
                        name: name,
                        count: manga[item.id]?.count ?? 0
                    )
                }
                .foregroundStyle(.primary)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if isLoading {
                ProgressView().progressViewStyle(.circular)
            }
        }
        .navigationTitle(embedded ? "" : NSLocalizedString("MIGRATE_SOURCES"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSources()
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateLibrary)) { _ in
            Task { await loadSources() }
        }
    }
}

extension MigrateSourcesView {
    struct SourceCell: View {
        let item: MigrateSourceInfo
        let name: String
        let count: Int

        var body: some View {
            HStack {
                SourceIconView(sourceId: item.id, imageUrl: item.coverUrl)
                    .padding(.trailing, 6)

                VStack(alignment: .leading) {
                    HStack {
                        Text(name)
                        Text(String(format: "(%i)", count))
                            .padding(.leading, -2)
                    }
                    if
                        !item.langs.isEmpty,
                        case let langString = SourceLanguage.displayName(for: SourceLanguage.primaryCode(for: item.langs))
                    {
                        Text(langString)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

extension MigrateSourcesView {
    func loadSources() async {
        manga = await CoreDataManager.shared.container.performBackgroundTask { context in
            let objects = CoreDataManager.shared.getLibraryManga(context: context)
            return Self.group(objects.compactMap { $0.manga?.toNewManga() })
        }
        sources = manga.keys
            .map { id in
                let source = SourceManager.shared.store.source(for: id)
                let coverUrl = source?.imageUrl
                return MigrateSourceInfo(
                    id: id,
                    name: source?.name,
                    langs: source?.languages ?? [],
                    coverUrl: coverUrl,
                    source: source
                )
            }
            .sorted { lhs, rhs in
                let languageOrder = SourceLanguage.compare(lhs.langs, rhs.langs)
                if languageOrder != .orderedSame {
                    return languageOrder == .orderedAscending
                }
                return (lhs.name ?? "").localizedCaseInsensitiveCompare(rhs.name ?? "") == .orderedAscending
            }
    }
}

extension MigrateSourcesView {
    /// The library by source key: each Suwayomi server source on its own.
    static func group(_ manga: [AidokuRunner.Manga]) -> [String: [AidokuRunner.Manga]] {
        Dictionary(grouping: manga, by: \.sourceKey)
    }
}
