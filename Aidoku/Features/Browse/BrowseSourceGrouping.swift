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
        let lowercased = language.lowercased()
        if lowercased == "all" || lowercased == "multi" || lowercased.isEmpty {
            return SourceLanguage.multi
        }
        return SourceLanguage.normalized(language)
    }

    /// Whether something in `languages` is shown with the active ones: several languages or «multi»
    /// always; otherwise its language must be active.
    static func isVisible(_ languages: [String], active: Set<String>) -> Bool {
        let primary = code(SourceLanguage.primaryCode(for: languages))
        if primary == SourceLanguage.multi {
            return true
        }
        return active.contains(primary)
    }

    /// SUWA-12 D M2: an installed source with library manga is always shown (Explorar) and searched (global
    /// search), whatever its language; the rest as `isVisible`.
    static func shows(languages: [String], sourceKey: String, active: Set<String>, inLibrary: Set<String>) -> Bool {
        inLibrary.contains(sourceKey) || isVisible(languages, active: active)
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
        var codes = Set<String>()
        for languages in installed {
            for language in languages {
                codes.insert(code(language))
            }
        }
        for language in external.union(server) {
            codes.insert(code(language))
        }
        codes.remove(SourceLanguage.multi)
        var sorted = codes.sorted { SourceLanguage.compare($0, $1) == .orderedAscending }
        if let localCode = localCode.map(code), let index = sorted.firstIndex(of: localCode) {
            sorted.remove(at: index)
            sorted.insert(localCode, at: 0)
        }
        return [SourceLanguage.multi] + sorted
    }

    static func toggled(_ language: String, in languages: Set<String>) -> Set<String> {
        let language = code(language)
        var languages = languages
        if languages.contains(language) {
            languages.remove(language)
        } else {
            languages.insert(language)
        }
        return languages
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
        var recents = load(from: defaults)
        recents[sourceKey] = date
        // only the latest ones are kept
        let latest = recents.sorted { $0.value > $1.value }.prefix(kept)
        defaults.set(Dictionary(uniqueKeysWithValues: latest.map { ($0.key, $0.value.timeIntervalSince1970) }), forKey: defaultsKey)
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
        inLibrary: Set<String> = [],
        localCode: String? = Locale.current.languageCode,
        showRecent: Bool = true
    ) -> BrowseSourceGroups {
        let visible = installed.filter {
            BrowseLanguages.shows(languages: $0.languages, sourceKey: $0.sourceId, active: active, inLibrary: inLibrary)
        }
        var result = BrowseSourceGroups()
        if showRecent {
            result.recent = recents
                .filter { key, _ in !pinnedKeys.contains(key) }
                .sorted { $0.value > $1.value }
                .compactMap { key, _ in visible.first { $0.sourceId == key } }
                .prefix(recentLimit)
                .map { $0 }
        }
        let grouped = Dictionary(grouping: visible) { info in
            BrowseLanguages.code(SourceLanguage.primaryCode(for: info.languages))
        }
        let local = localCode.map(BrowseLanguages.code)
        let codes = grouped.keys.sorted { lhs, rhs in
            // the device's language first, «multi» last, the rest by localized name
            if lhs == local { return true }
            if rhs == local { return false }
            if lhs == SourceLanguage.multi { return false }
            if rhs == SourceLanguage.multi { return true }
            return SourceLanguage.compare(lhs, rhs) == .orderedAscending
        }
        result.languages = codes.map { code in
            .init(
                code: code,
                sources: (grouped[code] ?? []).sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
        return result
    }
}

/// Source keys with manga in the library (SUWA-12 D M2).
enum LibrarySourceKeys {
    static func load(repos: DataRepositories = .shared) async -> Set<String> {
        await repos.library.sourceKeysInLibrary()
    }
}

/// What Explorar › Fuentes says when its list is empty.
enum BrowseEmptyState: Equatable {
    case hidden
    /// No source installed: add one.
    case noSources
    /// Sources installed, all in languages not chosen: choose languages.
    case filteredOut

    static func make(shown: Int, installed: Int, isSearching: Bool) -> BrowseEmptyState {
        if shown > 0 || isSearching { return .hidden }
        return installed > 0 ? .filteredOut : .noSources
    }
}
