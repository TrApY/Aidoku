//
//  ArchitectureLintTests.swift
//  AidokuTests
//
//  SUWA-13 F4 (D10): screens and services do not use Core Data directly. No file of Aidoku/ outside Core/Database
//  and outside `allowed` contains CoreDataManager.shared, import CoreData, NSManagedObject, NSPredicate or
//  NSSortDescriptor (an NSPredicate given to a PHFetchOptions is not Core Data); the contracts (Core/Repository) carry
//  no Core Data nor UIKit; and the repositories post no notifications nor touch settings (D6). `allowed` is what is
//  still to move: each lot removes what it moves, and an entry that no longer uses Core Data makes the test fail
//  too, so that the list only shrinks.
//

import Foundation
import Testing

@Suite struct ArchitectureLintTests {
    /// The repository: this file is AidokuTests/Repository/ArchitectureLintTests.swift.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let allowed: Set<String> = [
        "Aidoku/App/AppDelegate.swift",
        "Aidoku/Core/Backup/BackupManager.swift",
        "Aidoku/Core/Backup/Models/BackupCategory.swift",
        "Aidoku/Core/Backup/Models/BackupChapter.swift",
        "Aidoku/Core/Backup/Models/BackupHistory.swift",
        "Aidoku/Core/Backup/Models/BackupLibraryManga.swift",
        "Aidoku/Core/Backup/Models/BackupManga.swift",
        "Aidoku/Core/Backup/Models/BackupReadingSession.swift",
        "Aidoku/Core/Backup/Models/BackupSource.swift",
        "Aidoku/Core/Backup/Models/BackupTrackItem.swift",
        "Aidoku/Core/Backup/Models/BackupUpdate.swift",
        "Aidoku/Core/Backup/Models/BackupVocabEntry.swift",
        "Aidoku/Core/Dictionary/Vocab/VocabManager.swift",
        "Aidoku/Core/Downloads/DownloadManager.swift",
        "Aidoku/Core/Library/Models/Insights/InsightsData.swift",
        "Aidoku/Core/Library/Services/MangaManager.swift",
        "Aidoku/Core/Library/Services/MangaUpdateManager.swift",
        "Aidoku/Core/Sources/BuiltIn/Local/LocalFileDataManager.swift",
        "Aidoku/Core/Sources/BuiltIn/Local/LocalFileManager.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiServerSourceSync.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiSourceConversion.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiStartup.swift",
        "Aidoku/Core/Sources/SourceManager.swift",
        "Aidoku/Core/Tracking/TrackerManager.swift",
        "Aidoku/Core/Utilities/Concurrency/ObjectActorSerialExecutor.swift",
        "Aidoku/Extensions/CoreData/NSPersistentContainer.swift",
        "Aidoku/Features/Browse/AddSource/AddSourceView.swift",
        "Aidoku/Features/Manga/MangaView+ViewModel.swift",
        "Aidoku/Features/Settings/SettingsView.swift",
        "Aidoku/Features/Source/Legacy/SourceViewController.swift",
        "Aidoku/Features/Source/Legacy/SourceViewModel.swift",
        "Aidoku/Features/Updates/MangaUpdatesView.swift",
    ]

    static let patterns = ["CoreDataManager.shared", "import CoreData", "NSManagedObject", "NSPredicate", "NSSortDescriptor"]

    /// relative path → contents of every Swift file under `folder`
    static func sources(under folder: String) throws -> [String: String] {
        let base = root.appendingPathComponent(folder)
        var out: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return out
    }

    /// The patterns a file uses (an NSPredicate assigned to a PHFetchOptions does not count).
    static func coreDataUses(in text: String) -> Set<String> {
        let photoOptions = text.matches(of: #/let\s+(\w+)\s*=\s*PHFetchOptions\(\)/#).map { String($0.output.1) }
        var found: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            for pattern in patterns where line.contains(pattern) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if pattern == "NSPredicate", photoOptions.contains(where: { trimmed.hasPrefix("\($0).predicate =") }) {
                    continue
                }
                found.insert(pattern)
            }
        }
        return found
    }

    @Test func screensAndServicesDoNotUseCoreDataOutsideTheAllowedList() throws {
        let files = try Self.sources(under: "Aidoku")
        #expect(files.count > 400, "the sources were not found from \(Self.root.path)")
        let using = Set(files.filter { !$0.key.hasPrefix("Aidoku/Core/Database/") && !Self.coreDataUses(in: $0.value).isEmpty }.keys)
        let notAllowed = using.subtracting(Self.allowed).sorted()
        let stale = Self.allowed.subtracting(using).sorted()
        #expect(notAllowed == [], "these use Core Data directly and are not in the allowed list")
        #expect(stale == [], "these no longer use Core Data: take them out of the allowed list")
    }

    @Test func theContractsCarryNoCoreDataNorUIKit() throws {
        let files = try Self.sources(under: "Aidoku/Core/Repository")
        #expect(!files.isEmpty)
        for (path, text) in files {
            for banned in ["import CoreData", "import UIKit", "NSManagedObjectID"] {
                #expect(!text.contains(banned), "\(path): \(banned)")
            }
        }
    }

    @Test func theRepositoriesPostNothingNorTouchSettings() throws {
        let files = try Self.sources(under: "Aidoku/Core/Repository")
            .merging(try Self.sources(under: "Aidoku/Core/Database/Repository")) { first, _ in first }
        #expect(files.count >= 2)
        for (path, text) in files {
            for banned in ["NotificationCenter", "UserDefaults", "AppSettings", "CompletionJournal"] {
                #expect(!text.contains(banned), "\(path): \(banned)")
            }
        }
    }

    /// The values the contracts carry live with them (so they carry no UIKit either); their UI stays apart.
    @Test(arguments: ["LibraryFilter", "FilterGroup"])
    func theValuesOfTheContractsLiveWithThem(type: String) throws {
        let files = try Self.sources(under: "Aidoku")
        let declaring = files.filter { $0.value.contains("struct \(type):") }.keys.sorted()
        #expect(declaring.count == 1, "\(type) is declared in \(declaring)")
        #expect(declaring.allSatisfy { $0.hasPrefix("Aidoku/Core/Repository/Values/") }, "\(type) is declared in \(declaring)")
    }
}
