//
//  ErrorView.swift
//  Aidoku
//
//  Created by Skitty on 10/13/23.
//

import AidokuRunner
import SwiftUI
import Wasm3

// source error warning triangle with associated text and retry button if applicable
struct ErrorView: View {
    let error: Error
    var restart: (() async throws -> Void)?
    var retry: (() async -> Void)?
    /// Manga page: migrate the manga to another source.
    var migrate: (() -> Void)?
    /// Manga page: open the manga's web page.
    var openWeb: (() -> Void)?
    /// Text under the buttons.
    var footer: String?

    @State private var loading = false

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(.secondary)

            Group {
                let text = error.aidokuDescription()
                Text(text)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)

            if let retry {
                if let error = error as? SourceError {
                    if case .unimplemented = error {
                        // don't show retry button
                    } else {
                        retryButton(action: retry)
                    }
                } else if let restart, let error = error as? Wasm3Error {
                    switch error {
                        case .trap, .runtimeDisabled:
                            retryButton(title: NSLocalizedString("RESTART")) {
                                do {
                                    try await restart()
                                    await retry()
                                } catch {
                                    LogManager.logger.error("Failed to restart source: \(error)")
                                }
                            }
                        default:
                            EmptyView()
                    }
                }
            }

            if migrate != nil || openWeb != nil {
                HStack(spacing: 20) {
                    if let openWeb {
                        Button(action: openWeb) {
                            Label(NSLocalizedString("WEBVIEW"), systemImage: "safari")
                        }
                        .buttonStyle(.borderless)
                    }
                    if let migrate {
                        Button(action: migrate) {
                            Label(NSLocalizedString("MIGRATE"), systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.top, 4)
            }

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                    .padding(.horizontal)
            }
        }
    }

    @ContentBuilder
    func retryButton(title: String = NSLocalizedString("RETRY"), action: @escaping () async -> Void) -> some View {
        HStack {
            if loading {
                ProgressView().progressViewStyle(.circular)
            } else {
                Button {
                    withAnimation {
                        loading = true
                    }
                    Task {
                        await action()
                        withAnimation {
                            loading = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.medium))
                        Text(title)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 4)
    }
}
