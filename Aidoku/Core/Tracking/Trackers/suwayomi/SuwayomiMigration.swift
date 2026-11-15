//
//  SuwayomiMigration.swift
//  Aidoku
//
//  Keeps the Suwayomi server in step when a manga is migrated to another source (JoTa's rule: only the
//  new one stays in the server library, with what was read).
//

import AidokuRunner
import Foundation

/// What to do on the server when migrating `old` → `new`.
struct SuwayomiMigrationPlan: Equatable, Sendable {
    /// The Suwayomi track id the new manga gets (nil: the new one is not a server manga).
    var newTrackId: String?
    /// Put the new manga in the server library with what was read.
    var registerNew = false
    /// Take the old manga out of the server library.
    var removeOld = false

    static let none = SuwayomiMigrationPlan()

    static func trackId(for manga: MangaIdentifier) -> String {
        "\(manga.sourceKey)|\(manga.mangaKey)"
    }

    /// - oldIsServer / newIsServer: a manga of a Suwayomi source with tracking on (`canRegister`).
    /// - oldLeavesLibrary: migrate and «migrate and keep history» (the old one leaves the Aidoku library),
    ///   not copy.
    static func make(
        old: MangaIdentifier,
        new: MangaIdentifier,
        oldIsServer: Bool,
        newIsServer: Bool,
        oldLeavesLibrary: Bool
    ) -> SuwayomiMigrationPlan {
        .none // pending
    }
}

struct SuwayomiRemoveFromLibraryPayload: Encodable, Sendable {
    let variables: Variables
    let query = """
        mutation RemoveFromServerLibrary($id: Int!) {
          updateManga(input: {id: $id, patch: {inLibrary: false}}) {
            manga {
              id
              inLibrary
            }
          }
        }
        """

    struct Variables: Encodable, Sendable {
        let id: Int
    }
}

extension SuwayomiApi {
    /// Takes the manga out of the server library.
    func removeFromLibrary(sourceKey: String, seriesId: String) async throws {
        guard let mangaId = Int(seriesId) else { throw SuwayomiTrackerError.invalidId }
        let _: SuwayomiUpdateMangaResponse = try await helper(sourceKey: sourceKey).request(
            body: SuwayomiRemoveFromLibraryPayload(variables: .init(id: mangaId))
        )
    }
}

extension SuwayomiTracker {
    /// Applies the plan on the server. Best effort: a failure is logged and never undoes the migration
    /// on the device (the new manga is put in the server library again by the tracker's next update).
    func applyMigration(
        _ plan: SuwayomiMigrationPlan,
        old: MangaIdentifier,
        highestChapterRead: Float?
    ) async {
        // pending
    }
}
