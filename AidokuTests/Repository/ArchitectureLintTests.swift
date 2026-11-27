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

    /// What F4 leaves on Core Data. Aidoku/Core/Database/ is not listed: it is Core Data's own folder and the test
    /// leaves it out by its prefix.
    static let allowed: Set<String> = [
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
        "Aidoku/Core/Sources/BuiltIn/Local/LocalFileDataManager.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiServerSourceSync.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiSourceConversion.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiStartup.swift",
        "Aidoku/Core/Utilities/Concurrency/ObjectActorSerialExecutor.swift",
        "Aidoku/Extensions/CoreData/NSPersistentContainer.swift",
    ]

    /// What counts as Core Data, looked for in the whole text of a file (bajo nº 3: a name split over lines too).
    static let patterns = [
        #"CoreDataManager\s*\.\s*shared"#,
        #"import\s+CoreData\b"#,
        "NSManagedObject",
        "NSPredicate",
        "NSSortDescriptor",
        "NSFetchRequest",
        #"\b(Manga|Chapter|History|LibraryManga|LocalFileInfo|Category|Track|Source|MangaUpdate|ReadingSession|Vocab\w*)Object\b"#,
    ]

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

    /// The patterns a file uses, in its whole text (an NSPredicate assigned to a PHFetchOptions does not count).
    static func coreDataUses(in text: String) -> Set<String> {
        var text = text
        for name in text.matches(of: #/let\s+(\w+)\s*=\s*PHFetchOptions\(\)/#).map({ String($0.output.1) }) {
            guard let given = try? Regex("\\b\(name)\\s*\\.\\s*predicate\\s*=\\s*NSPredicate").wordBoundaryKind(.simple) else {
                continue
            }
            text = text.replacing(given, with: "")
        }
        // `\b` as a word boundary between a word and anything else (Swift's default is Unicode's, which keeps
        // `MangaObject.fetchRequest` as one word)
        return Set(patterns.filter { pattern in
            (try? Regex(pattern)).map { text.contains($0.wordBoundaryKind(.simple)) } ?? true
        })
    }

    @Test func screensAndServicesDoNotUseCoreDataOutsideTheAllowedList() throws {
        let files = try Self.sources(under: "Aidoku")
        #expect(files.count > 400, "the sources were not found from \(Self.root.path)")
        // Core/Database is Core Data itself
        let using = Set(files.filter { !$0.key.hasPrefix("Aidoku/Core/Database/") && !Self.coreDataUses(in: $0.value).isEmpty }.keys)
        let notAllowed = using.subtracting(Self.allowed).sorted()
        let stale = Self.allowed.subtracting(using).sorted()
        #expect(notAllowed == [], "these use Core Data directly and are not in the allowed list")
        #expect(stale == [], "these no longer use Core Data: take them out of the allowed list")
    }

    /// SUWA-13 F4 L12 (D-L12-12): the closed list. What is left in `allowed` is what F4 leaves on Core Data on
    /// purpose (D11): the backups, the Suwayomi conversion with its sync and its start, the local files, the
    /// vocabulary, their executor and the container's helper. Nothing else may join it.
    static let closedList = [
        "Aidoku/Core/Backup/",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiSourceConversion.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiServerSourceSync.swift",
        "Aidoku/Core/Sources/BuiltIn/Suwayomi/SuwayomiStartup.swift",
        "Aidoku/Core/Sources/BuiltIn/Local/LocalFileDataManager.swift",
        "Aidoku/Core/Dictionary/Vocab/VocabManager.swift",
        "Aidoku/Core/Utilities/Concurrency/ObjectActorSerialExecutor.swift",
        "Aidoku/Extensions/CoreData/NSPersistentContainer.swift",
    ]

    @Test func everyAllowedFileMatchesTheClosedList() {
        let outside = Self.allowed.filter { file in !Self.closedList.contains { file.hasPrefix($0) } }.sorted()
        #expect(outside == [], "these are not in the closed list")
        #expect(Self.allowed.count == 18)
    }

    /// Uses the line by line check did not see (bajo nº 3): a name split over lines, a fetch request, a managed
    /// object class.
    @Test(arguments: [
        "let container = CoreDataManager\n    .shared\n    .container",
        "let request = NSFetchRequest<NSFetchRequestResult>(entityName: \"Manga\")",
        "func read(_ entry: LibraryMangaObject) {}",
        // a class name followed by a member: Swift's default word boundary does not cut there
        "let request = MangaObject.fetchRequest()",
        // every entity of the 0.9 model has its class: LocalFileInfo was missing from the list
        "let x = LocalFileInfoObject(context: c)",
    ])
    func aUseTheLineCheckMissedIsFound(text: String) {
        #expect(!Self.coreDataUses(in: text).isEmpty, "\(text)")
    }

    /// An NSPredicate given to a PHFetchOptions is still not Core Data; any other one is.
    @Test func aPhotoFetchPredicateIsNotCoreData() {
        let text = "let options = PHFetchOptions()\noptions.predicate = NSPredicate(format: \"mediaType == %d\", 1)"
        #expect(Self.coreDataUses(in: text).isEmpty)
        #expect(!Self.coreDataUses(in: text + "\nlet other = NSPredicate(value: true)").isEmpty)
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

    /// SUWA-13 F4 L11 (D-L11-8): the big transactions went to the repositories, so the functions they left open no
    /// context of their own any more. Their files stay in `allowed` for their other uses (L12).
    @Test func theMovedTransactionsOpenNoContext() throws {
        let files = try Self.sources(under: "Aidoku")
        for (path, function) in [
            ("Aidoku/Core/Library/Services/MangaManager.swift", "static func migrate("),
            ("Aidoku/Core/Tracking/TrackerManager.swift", "func syncPageTrackerHistory("),
            ("Aidoku/App/AppDelegate.swift", "func handleSourceMigration("),
        ] {
            let text = try #require(files[path], "\(path)")
            let body = try #require(Self.body(of: function, in: text), "\(path): \(function)")
            #expect(!body.contains("performBackgroundTask"), "\(path): \(function)")
            #expect(!body.contains("CoreDataManager.shared"), "\(path): \(function)")
        }
    }

    /// The body is the function's, not that of a closure given as a default value of a parameter
    /// (TrackerManager.syncPageTrackerHistory has two).
    @Test func theBodyOfAFunctionIsNotADefaultArgument() {
        let text = """
            func f(a: (Int) -> Int = { $0 }, b: @escaping () -> Void = {}) async {
                work()
            }
            """
        #expect(Self.body(of: "func f(", in: text) == "{\n    work()\n}")
    }

    /// The text of the function that starts with `signature` (ending in the parameters' opening parenthesis, found once),
    /// from the first opening brace after its parameters to the one that closes it.
    static func body(of signature: String, in text: String) -> String? {
        let starts = text.ranges(of: signature)
        guard starts.count == 1, signature.hasSuffix("(") else { return nil }
        // past the parameters: their default values can be closures
        var parentheses = 1
        var position = starts[0].upperBound
        while position < text.endIndex, parentheses > 0 {
            if text[position] == "(" {
                parentheses += 1
            } else if text[position] == ")" {
                parentheses -= 1
            }
            position = text.index(after: position)
        }
        guard let open = text[position...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[open...index])
                    }
                default: break
            }
            index = text.index(after: index)
        }
        return nil
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
