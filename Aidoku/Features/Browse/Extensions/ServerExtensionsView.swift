//
//  ServerExtensionsView.swift
//  Aidoku
//
//  SUWA-12 B3: Explorar › Extensiones (the Suwayomi server's extensions).
//

import SwiftUI

/// The server's GraphQL API for extensions, with the connection's login.
struct SuwayomiExtensionsAPI: ServerExtensionsAPI {
    let connectionKey: String

    private static let fields = "pkgName name lang versionName isInstalled hasUpdate isObsolete iconUrl contentWarning source { nodes { id } }"

    private struct Query: Encodable {
        let query: String
    }

    private struct ListResponse: Decodable {
        struct DataContainer: Decodable {
            struct Nodes: Decodable { let nodes: [ServerExtension] }
            let extensions: Nodes
        }
        let data: DataContainer
    }

    private struct FetchResponse: Decodable {
        struct DataContainer: Decodable {
            struct Payload: Decodable { let extensions: [ServerExtension] }
            let fetchExtensions: Payload
        }
        let data: DataContainer
    }

    private struct MutationResponse: Decodable {
        let data: [String: AnyDecodable]?
        struct AnyDecodable: Decodable {
            init(from decoder: Decoder) throws {}
        }
    }

    private var helper: SuwayomiHelper { SuwayomiHelper(sourceKey: connectionKey) }

    func list() async throws -> [ServerExtension] {
        let response: ListResponse = try await helper.request(
            body: Query(query: "{ extensions { nodes { \(Self.fields) } } }"),
            timeout: 30
        )
        return response.data.extensions.nodes
    }

    func fetch() async throws -> [ServerExtension] {
        let response: FetchResponse = try await helper.request(
            body: Query(query: "mutation { fetchExtensions(input: {}) { extensions { \(Self.fields) } } }"),
            timeout: 60
        )
        return response.data.fetchExtensions.extensions
    }

    func apply(_ action: ServerExtensionAction, to pkgName: String) async throws {
        let id = pkgName.replacingOccurrences(of: "\"", with: "")
        let _: MutationResponse = try await helper.request(
            body: Query(query: "mutation { updateExtension(input: {id: \"\(id)\", patch: {\(action.rawValue): true}}) { extension { pkgName } } }"),
            timeout: 120
        )
    }

    func apply(_ action: ServerExtensionAction, to pkgNames: [String]) async throws {
        let ids = pkgNames.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: ",")
        let _: MutationResponse = try await helper.request(
            body: Query(query: "mutation { updateExtensions(input: {ids: [\(ids)], patch: {\(action.rawValue): true}}) { extensions { pkgName } } }"),
            timeout: 300
        )
    }
}

extension ServerExtensionsModel {
    /// With the first Suwayomi connection installed (nil if there's none).
    static func live() async -> ServerExtensionsModel {
        let connection = await SourceManager.shared.suwayomiConnections().first?.key
        return ServerExtensionsModel(
            api: connection.map { SuwayomiExtensionsAPI(connectionKey: $0) },
            resync: {
                // in the same queue as the start's sync and conversion: never at once (B4)
                await SuwayomiStartup.shared.resyncSources()
                NotificationCenter.default.post(name: .updateSourceList, object: nil)
            },
            libraryCount: { serverSourceIds in
                guard let connection else { return ServerExtensionLibraryCount() }
                return try await ServerExtensionsModel.countLibrary(
                    connection: connection,
                    serverSourceIds: serverSourceIds
                )
            }
        )
    }
}

struct ServerExtensionsView: View {
    @State private var model: ServerExtensionsModel?

    var body: some View {
        Group {
            if let model {
                ServerExtensionsList(model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil {
                model = await ServerExtensionsModel.live()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateSourceList)) { _ in
            // a connection added or removed in Ajustes
            Task {
                let hasConnection = await !SourceManager.shared.suwayomiConnections().isEmpty
                if hasConnection != (model?.state != .noConnection) {
                    model = await ServerExtensionsModel.live()
                }
            }
        }
    }
}

private struct ServerExtensionsList: View {
    @ObservedObject var model: ServerExtensionsModel

    @State private var query = ""
    @State private var languages = BrowseLanguages.active()
    @State private var toUninstall: ServerExtension?
    @State private var toUninstallAgain: ServerExtension?
    /// nil: it may have library manga, how many isn't known.
    @State private var libraryCount: Int?

    @EnvironmentObject private var path: NavigationCoordinator

    var body: some View {
        content
            .task { await model.load() }
            .onReceive(NotificationCenter.default.publisher(for: .browseLanguagesChanged)) { _ in
                languages = BrowseLanguages.active()
            }
            .confirmationDialog(
                String(format: NSLocalizedString("EXTENSION_UNINSTALL_CONFIRM_%@"), toUninstall?.name ?? ""),
                isPresented: Binding(get: { toUninstall != nil }, set: { if !$0 { toUninstall = nil } }),
                titleVisibility: .visible,
                presenting: toUninstall
            ) { ext in
                Button(NSLocalizedString("UNINSTALL"), role: .destructive) {
                    Task {
                        let check = await model.uninstallCheck(of: ext)
                        if check.confirmations > 1 {
                            libraryCount = check.count
                            toUninstallAgain = ext // asked twice when it may have library manga
                        } else {
                            await model.perform(.uninstall, on: ext)
                        }
                    }
                }
            }
            .alert(
                NSLocalizedString("EXTENSION_UNINSTALL_LIBRARY_TITLE"),
                isPresented: Binding(get: { toUninstallAgain != nil }, set: { if !$0 { toUninstallAgain = nil } }),
                presenting: toUninstallAgain
            ) { ext in
                Button(NSLocalizedString("CANCEL"), role: .cancel) {}
                Button(NSLocalizedString("UNINSTALL"), role: .destructive) {
                    Task { await model.perform(.uninstall, on: ext) }
                }
            } message: { ext in
                Text(
                    libraryCount.map { String(format: NSLocalizedString("EXTENSION_UNINSTALL_LIBRARY_%@_%i"), ext.name, $0) }
                        ?? String(format: NSLocalizedString("EXTENSION_UNINSTALL_LIBRARY_MAYBE_%@"), ext.name)
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
            case .noConnection:
                VStack(spacing: 12) {
                    Text(NSLocalizedString("EXTENSIONS_NO_CONNECTION"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("SUWAYOMI_SERVER")) {
                        path.push(SuwayomiServerSettingsView())
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                VStack(spacing: 12) {
                    Text(NSLocalizedString("EXTENSIONS_SERVER_DOWN"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("RETRY")) {
                        Task { await model.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                list
        }
    }

    private var list: some View {
        let sections = ServerExtensionSections.make(model.extensions, active: languages, query: query)
        return List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(NSLocalizedString("EXTENSIONS_SEARCH"), text: $query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            if !sections.updates.isEmpty {
                Section {
                    ForEach(sections.updates) { row($0, action: .update) }
                } header: {
                    HStack {
                        Text(NSLocalizedString("EXTENSIONS_UPDATES"))
                        Spacer()
                        Button(NSLocalizedString("EXTENSIONS_UPDATE_ALL")) {
                            Task { await model.updateAll() }
                        }
                        .disabled(model.isUpdatingAll)
                        .textCase(nil)
                    }
                }
            }
            if !sections.installed.isEmpty {
                Section(NSLocalizedString("EXTENSIONS_INSTALLED")) {
                    ForEach(sections.installed) { row($0, action: .uninstall) }
                }
            }
            ForEach(sections.available, id: \.code) { group in
                Section(String(format: NSLocalizedString("EXTENSIONS_AVAILABLE_%@"), SourceLanguage.displayName(for: group.code))) {
                    ForEach(group.extensions) { row($0, action: .install) }
                }
            }
            if sections.isEmpty {
                Text(NSLocalizedString("EXTENSIONS_NONE"))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.load(refresh: true) }
    }

    private func row(_ ext: ServerExtension, action: ServerExtensionAction) -> some View {
        HStack(spacing: 12) {
            ServerExtensionIcon(ext: ext)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ext.name).lineLimit(1)
                    if ext.isNsfw {
                        ExtensionBadge(text: NSLocalizedString("BADGE_18"), color: .red)
                    } else if ext.isPartlyNsfw {
                        ExtensionBadge(text: NSLocalizedString("BADGE_18_PARTLY"), color: .orange)
                    }
                    if ext.isMultiLanguage {
                        ExtensionBadge(text: NSLocalizedString("BADGE_MIXED"), color: .blue)
                    }
                }
                Text("\(SourceLanguage.displayName(for: BrowseLanguages.code(ext.lang))) · \(ext.versionName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy[ext.pkgName] != nil {
                ProgressView()
            } else {
                Button(NSLocalizedString(action == .install ? "EXTENSION_INSTALL" : action == .update ? "EXTENSION_UPDATE" : "UNINSTALL")) {
                    if action == .uninstall {
                        toUninstall = ext
                    } else {
                        Task { await model.perform(action, on: ext) }
                    }
                }
                .buttonStyle(.bordered)
                .tint(action == .uninstall ? .red : .accentColor)
                .font(.footnote)
            }
        }
    }
}

private struct ExtensionBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
    }
}

/// The icon with the connection's login (Nuke has no auth), kept in memory.
private struct ServerExtensionIcon: View {
    let ext: ServerExtension

    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Image(.suwayomi).resizable()
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: ext.pkgName) {
            if let cached = Self.cache.object(forKey: ext.pkgName as NSString) {
                image = cached
                return
            }
            guard
                let connection = await SourceManager.shared.suwayomiConnections().first?.key,
                case let helper = SuwayomiHelper(sourceKey: connection),
                let baseUrl = try? helper.getConfiguredServer(),
                let url = SuwayomiServerSources.iconUrl(ext.iconUrl, baseUrl: baseUrl)
            else { return }
            // the login only to the connection's server, and no disk cache (B5)
            let request = SuwayomiIconLoading.request(url, server: baseUrl, timeout: 20) { helper.authorize(request: &$0) }
            if
                let (data, _) = try? await SuwayomiIconLoading.session.data(for: request),
                let loaded = UIImage(data: data)
            {
                Self.cache.setObject(loaded, forKey: ext.pkgName as NSString)
                image = loaded
            }
        }
    }
}

/// B2: the active languages, with checkboxes (the same Browse.languages as Añadir fuente).
struct BrowseLanguagesView: View {
    @State private var options: [String] = []
    @State private var selected = BrowseLanguages.active()

    var body: some View {
        List(options, id: \.self) { code in
            Button {
                selected = BrowseLanguages.toggled(code, in: selected)
                BrowseLanguages.set(selected)
            } label: {
                HStack {
                    Text(SourceLanguage.displayName(for: code))
                    Spacer()
                    if selected.contains(code) {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .navigationTitle(NSLocalizedString("LANGUAGES"))
        .navigationBarTitleDisplayMode(.inline)
        // closed with the sheet's own close button (SwiftUINavigationViewController)
        .task {
            let installed = await SourceManager.shared.getSourceInfos(listedOnly: true).map(\.languages)
            let external = await SourceManager.shared.getSourceListLanguages()
            options = BrowseLanguages.options(installed: installed, external: external, server: ServerExtensionLanguages.known)
        }
    }
}

/// The languages of the server extensions last seen (for the language list).
enum ServerExtensionLanguages {
    nonisolated(unsafe) static var known: [String] = []
}
