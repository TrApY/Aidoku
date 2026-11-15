//
//  BrowseSourceGrouping.swift
//  Aidoku
//
//  SUWA-12 B1/B2: Explorar › Fuentes as Tachimanga: pinned first, then «Usado recientemente», then one
//  section per language, only for the active languages (Browse.languages; «multi» always shown). The
//  active languages are the same setting for Explorar, Añadir fuente, Extensiones and the global search.
//

import Foundation

/// The active languages (Browse.languages), shared by every screen that filters by language.
enum BrowseLanguages {
    static func active() -> Set<String> {
        AppSettings.browse.languages.get()
    }

    static func set(_ languages: Set<String>) {
        AppSettings.browse.languages.set(languages)
        NotificationCenter.default.post(name: .filterExternalSources, object: nil)
        NotificationCenter.default.post(name: .browseLanguagesChanged, object: nil)
    }

    /// A language code as the setting keeps it («all» of the server extensions is «multi»).
    static func code(_ language: String) -> String {
        language // pendiente
    }

    /// Whether something in `languages` is shown with the active ones: several languages or «multi»
    /// always; otherwise its language must be active.
    static func isVisible(_ languages: [String], active: Set<String>) -> Bool {
        true // pendiente
    }

    /// The languages offered to choose from: those of the installed sources, of the external source
    /// lists and of the server extensions, without repeats; «multi» first, then the device's language,
    /// then the rest by localized name.
    static func options(
        installed: [[String]],
        external: Set<String>,
        server: [String],
        localCode: String? = Locale.current.languageCode
    ) -> [String] {
        [] // pendiente
    }

    static func toggled(_ language: String, in languages: Set<String>) -> Set<String> {
        languages // pendiente
    }
}

/// When each source was last opened from Explorar (for «Usado recientemente»).
enum SourceRecents {
    static let defaultsKey = "Browse.recentSources"
    static let kept = 20

    static func load(from defaults: UserDefaults = .standard) -> [String: Date] {
        let raw = defaults.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func record(_ sourceKey: String, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        return // pendiente
    }
}

struct BrowseSourceGroups: Equatable {
    struct LanguageGroup: Equatable {
        let code: String
        let sources: [SourceInfo]
    }

    var recent: [SourceInfo] = []
    var languages: [LanguageGroup] = []

    static let recentLimit = 3

    /// - installed: the installed sources that aren't pinned.
    /// - pinnedKeys: the pinned ones (never repeated in «Usado recientemente»).
    static func make(
        installed: [SourceInfo],
        pinnedKeys: Set<String>,
        recents: [String: Date],
        active: Set<String>,
        localCode: String? = Locale.current.languageCode,
        showRecent: Bool = true
    ) -> BrowseSourceGroups {
        BrowseSourceGroups(languages: [.init(code: SourceLanguage.multi, sources: installed)]) // pendiente
    }
}
