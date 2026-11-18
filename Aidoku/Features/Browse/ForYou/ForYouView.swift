//
//  ForYouView.swift
//  Aidoku
//
//  SUWA-18: Explorar › «Para ti», the recommendations the suwa-recs service leaves on the Suwayomi
//  server (`suwa.recs.v1`). Read when the tab opens for the first time in the session and on pull to
//  refresh; nothing is computed in the app.
//

import AidokuRunner
import SwiftUI

/// The tabs of Explorar, in their order in the segmented control.
enum BrowseTab: Int, CaseIterable {
    case sources
    case extensions
    case migrate
    case forYou

    /// The tabs shown, in order (their index is the segment index).
    static var shown: [BrowseTab] {
        allCases
    }

    var titleKey: String {
        switch self {
            case .sources: "EXPLORE_SOURCES"
            case .extensions: "EXPLORE_EXTENSIONS"
            case .migrate: "EXPLORE_MIGRATE"
            case .forYou: "EXPLORE_FOR_YOU"
        }
    }
}

/// What «Para ti» shows.
enum ForYouState: Equatable {
    case loading
    /// No Suwayomi connection: «Conecta el servidor Suwayomi en Ajustes».
    case noServer
    /// The server has no recommendations (or they aren't valid): «Aún no hay recomendaciones…».
    case empty
    /// The server couldn't be read and there is nothing to show: message and «Reintentar».
    case error
    case loaded(updated: String?, entries: [SuwayomiRecs.Entry])

    /// The state for a read: `result` = what the server answered now (nil while loading or after a
    /// failure), `failed` = the read failed, `shown` = what is on screen or in Caches/ (kept when a read
    /// fails). A last run with `ok:false` changes nothing: the list and its date stay as they are.
    static func make(
        hasConnection: Bool,
        result: SuwayomiRecs.ForYouResult?,
        failed: Bool,
        shown: SuwayomiRecs.ForYouResult?,
        updatedText: (String?) -> String? = { SuwayomiRecs.updatedText(at: $0) }
    ) -> ForYouState {
        guard hasConnection else { return .noServer }
        if let result {
            return result.entries.isEmpty ? .empty : .loaded(updated: updatedText(result.at), entries: result.entries)
        }
        if let shown, !shown.entries.isEmpty {
            return .loaded(updated: updatedText(shown.at), entries: shown.entries)
        }
        return failed ? .error : .loading
    }

    /// Localization key of the message of a state without a list.
    var messageKey: String? {
        switch self {
            case .noServer: "FOR_YOU_NO_SERVER"
            case .empty: "FOR_YOU_EMPTY"
            case .error: "FOR_YOU_ERROR"
            case .loading, .loaded: nil
        }
    }
}

@MainActor
final class ForYouViewModel: ObservableObject {
    @Published private(set) var state: ForYouState = .loading

    private let connection: () async -> String?
    private let cache: SuwayomiRecsCache
    private let transport: SuwayomiHelper.Transport?
    private var shown: SuwayomiRecs.ForYouResult?
    private var loaded = false

    init(
        connection: @escaping () async -> String? = { await ForYouViewModel.firstConnection() },
        cache: SuwayomiRecsCache = .shared,
        transport: SuwayomiHelper.Transport? = nil
    ) {
        self.connection = connection
        self.cache = cache
        self.transport = transport
    }

    /// The first Suwayomi connection with a server configured.
    static func firstConnection() async -> String? {
        await SuwayomiStartup.connectionKeys().sorted().first {
            UserDefaults.standard.string(forKey: "\($0).server") != nil
        }
    }

    /// First time the tab is shown in the session (the memory cache keeps it for the next times).
    func loadIfNeeded() async {
        guard !loaded else { return }
        await load(force: false)
    }

    /// `force`: pull to refresh, reads the meta again.
    func load(force: Bool) async {
        loaded = true
        guard let parentKey = await connection() else {
            state = ForYouState.make(hasConnection: false, result: nil, failed: false, shown: nil)
            return
        }
        let key = "\(parentKey)|for-you"
        if !force, let cached: SuwayomiRecs.ForYouResult = await cache.memory(key) {
            shown = cached
            state = ForYouState.make(hasConnection: true, result: cached, failed: false, shown: nil)
            return
        }
        if shown == nil {
            shown = await cache.stored(key)
        }
        if case .loaded = state {} else {
            state = ForYouState.make(hasConnection: true, result: nil, failed: false, shown: shown)
        }
        do {
            let result = try await SuwayomiRecsReader(parentKey: parentKey, transport: transport).forYou()
            await cache.set(result, for: key)
            shown = result
            state = ForYouState.make(hasConnection: true, result: result, failed: false, shown: nil)
        } catch {
            LogManager.logger.warn("Para ti no leído: \(error)")
            state = ForYouState.make(hasConnection: true, result: nil, failed: true, shown: shown)
        }
    }
}

struct ForYouView: View {
    @StateObject private var viewModel: ForYouViewModel
    @EnvironmentObject private var path: NavigationCoordinator

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)]

    init(viewModel: @autoclosure @escaping () -> ForYouViewModel = ForYouViewModel()) {
        self._viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .refreshable {
            await viewModel.load(force: true)
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            case let .loaded(updated, entries):
                grid(updated: updated, entries: entries)
            case .noServer, .empty, .error:
                message(viewModel.state)
        }
    }

    private func message(_ state: ForYouState) -> some View {
        VStack(spacing: 12) {
            Image(systemName: state == .error ? "exclamationmark.triangle" : "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString(state.messageKey ?? ""))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if state == .error {
                Button(NSLocalizedString("RETRY")) {
                    Task { await viewModel.load(force: true) }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }

    private func grid(updated: String?, entries: [SuwayomiRecs.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let updated {
                Text(updated)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(entries) { entry in
                    card(entry)
                }
            }
        }
    }

    private func card(_ entry: SuwayomiRecs.Entry) -> some View {
        let source = SourceManager.shared.store.source(for: entry.sourceKey)
        return Button {
            path.push(MangaViewController(source: source, manga: entry.manga, parent: path.rootViewController))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                MangaGridItem(source: source, title: entry.title, coverImage: entry.cover ?? "")
                if !entry.sourceName.isEmpty {
                    Text(entry.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !entry.reason.isEmpty {
                    Text(entry.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
