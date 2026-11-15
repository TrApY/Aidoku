//
//  AddSourceFilterMenu.swift
//  Aidoku
//
//  Created by Skitty on 12/15/25.
//

import AidokuRunner
import SwiftUI

struct AddSourceFilterMenu: View {
    private struct LanguageItem: Hashable, Identifiable {
        let id: String
        let title: String
    }

    @State private var languages: [LanguageItem] = []
    @State private var contentRatings: Set<AidokuRunner.SourceContentRating>
    @State private var selectedLanguages: Set<String>

    @Environment(\.dismiss) private var dismiss

    init() {
        self._contentRatings = State(initialValue: AppSettings.browse.contentRatings.get())
        self._selectedLanguages = State(initialValue: AppSettings.browse.languages.get())
    }

    var body: some View {
        Menu {
            Menu {
                ForEach(SourceContentRating.allCases, id: \.rawValue) { rating in
                    let isEnabled = contentRatings.contains(rating)
                    Button {
                        if isEnabled {
                            contentRatings.remove(rating)
                        } else {
                            contentRatings.insert(rating)
                        }
                    } label: {
                        HStack {
                            Text(rating.title)
                            Spacer()
                            if isEnabled {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .menuActionDismissDisabled()
            } label: {
                Label(NSLocalizedString("CONTENT_RATING"), systemImage: "exclamationmark.triangle.fill")
            }
            Menu {
                ForEach(languages) { language in
                    let code = BrowseLanguages.code(language.id)
                    let isEnabled = selectedLanguages.contains(code)
                    Button {
                        selectedLanguages = BrowseLanguages.toggled(code, in: selectedLanguages)
                    } label: {
                        HStack {
                            Text(language.title)
                            Spacer()
                            if isEnabled {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .menuActionDismissDisabled()
            } label: {
                Label(NSLocalizedString("LANGUAGES"), systemImage: "globe")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .onChange(of: contentRatings) { _ in
            AppSettings.browse.contentRatings.set(contentRatings)
            NotificationCenter.default.post(name: .filterExternalSources, object: nil)
        }
        .onChange(of: selectedLanguages) { _ in
            BrowseLanguages.set(selectedLanguages)
        }
        .onReceive(NotificationCenter.default.publisher(for: .browseLanguagesChanged)) { _ in
            let active = BrowseLanguages.active()
            if active != selectedLanguages {
                selectedLanguages = active
            }
        }
        .task {
            guard languages.isEmpty else { return }

            // the same list as the language button of Explorar
            let installed = await SourceManager.shared.getSourceInfos(listedOnly: true).map(\.languages)
            let languageCodes = BrowseLanguages.options(
                installed: installed,
                external: await SourceManager.shared.getSourceListLanguages(),
                server: ServerExtensionLanguages.known
            )

            self.languages = languageCodes.map { code in
                .init(
                    id: code,
                    title: SourceLanguage.displayName(for: code)
                )
            }
        }
    }
}
