//
//  SuwayomiServerSettingsView.swift
//  Aidoku
//
//  SUWA-12 D5: Ajustes › «Servidor Suwayomi». The connection isn't a source of Explorar any more; its
//  address and login are edited here, with the server sources it brings and the manga still waiting to
//  be converted to them.
//

import SwiftUI

struct SuwayomiServerSettingsView: View {
    @State private var connections: [(key: String, name: String)] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded {
                ProgressView()
            } else if let connection = connections.first {
                SuwayomiConnectionForm(key: connection.key, name: connection.name) {
                    Task { await load() }
                }
            } else {
                List {
                    Section {
                        NavigationLink(NSLocalizedString("SUWAYOMI_CONFIGURE")) {
                            SuwayomiSetupView()
                        }
                    } footer: {
                        Text(NSLocalizedString("SUWAYOMI_INFO"))
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("SUWAYOMI_SERVER"))
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .updateSourceList)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        connections = await SourceManager.shared.suwayomiConnections()
        loaded = true
    }
}

private struct SuwayomiConnectionForm: View {
    let key: String
    let name: String
    let removed: () -> Void

    @State private var values = SuwayomiConnectionSettings.Values(server: "", username: "", password: "")
    @State private var saved = SuwayomiConnectionSettings.Values(server: "", username: "", password: "")
    @State private var testResult: String?
    @State private var testing = false
    @State private var sources: (available: Int, total: Int) = (0, 0)
    @State private var pending: Int?
    @State private var converting = false
    @State private var showingRemove = false
    @State private var invalidServer = false

    var body: some View {
        List {
            Section {
                TextField(NSLocalizedString("SERVER_URL"), text: $values.server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(NSLocalizedString("USERNAME"), text: $values.username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(NSLocalizedString("PASSWORD"), text: $values.password)
                    .textContentType(.password)
            } header: {
                Text(name)
            } footer: {
                if invalidServer {
                    Text(NSLocalizedString("SUWAYOMI_INVALID_SERVER"))
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(NSLocalizedString("SUWAYOMI_TEST_CONNECTION")) {
                    Task { await test() }
                }
                .disabled(testing)
                if testing {
                    ProgressView()
                } else if let testResult {
                    Text(testResult)
                        .foregroundStyle(.secondary)
                }
                Button(NSLocalizedString("SAVE")) {
                    Task { await save() }
                }
                .disabled(values == saved)
            }

            Section {
                HStack {
                    Text(NSLocalizedString("SUWAYOMI_SERVER_SOURCE_COUNT"))
                    Spacer()
                    Text(sources.available == sources.total ? "\(sources.total)" : "\(sources.available) / \(sources.total)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(NSLocalizedString("SUWAYOMI_PENDING_CONVERSION"))
                    Spacer()
                    if converting || pending == nil {
                        ProgressView()
                    } else {
                        Text("\(pending ?? 0)")
                            .foregroundStyle(.secondary)
                    }
                }
                Button(NSLocalizedString("RETRY")) {
                    Task { await convert() }
                }
                .disabled(converting)
            } footer: {
                Text(NSLocalizedString("SUWAYOMI_PENDING_CONVERSION_INFO"))
            }

            Section {
                Button(NSLocalizedString("SUWAYOMI_REMOVE_CONNECTION"), role: .destructive) {
                    showingRemove = true
                }
            }
        }
        .confirmationDialog(
            NSLocalizedString("SUWAYOMI_REMOVE_CONNECTION_CONFIRM"),
            isPresented: $showingRemove,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("SUWAYOMI_REMOVE_CONNECTION"), role: .destructive) {
                Task {
                    await SourceManager.shared.removeSuwayomiConnection(key)
                    removed()
                }
            }
        }
        .task {
            values = SuwayomiConnectionSettings.load(key: key)
            saved = values
            await refreshCounts()
        }
    }

    private func refreshCounts() async {
        sources = await SourceManager.shared.suwayomiServerSourceCount(connection: key)
        pending = await SuwayomiStartup.pendingCount()
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard
            let server = SuwayomiConnectionSettings.normalizedServer(values.server),
            let url = URL(string: server)
        else {
            invalidServer = true
            testResult = nil
            return
        }
        invalidServer = false
        guard let loginType = await SuwayomiHelper.getLoginType(server: url) else {
            testResult = NSLocalizedString("SUWAYOMI_TEST_NO_SERVER")
            return
        }
        if loginType == .none {
            testResult = NSLocalizedString("SUWAYOMI_TEST_OK")
        } else if await SuwayomiHelper.checkLogin(server: url, username: values.username, password: values.password) != nil {
            testResult = NSLocalizedString("SUWAYOMI_TEST_OK")
        } else {
            testResult = NSLocalizedString("SUWAYOMI_TEST_LOGIN_FAILED")
        }
    }

    private func save() async {
        guard SuwayomiConnectionSettings.save(values, key: key) else {
            invalidServer = true
            return
        }
        invalidServer = false
        values = SuwayomiConnectionSettings.load(key: key)
        saved = values
        // the server may have other sources now, and manga can be converted
        await convert()
    }

    private func convert() async {
        converting = true
        await SuwayomiStartup.shared.convert()
        await refreshCounts()
        converting = false
    }
}
