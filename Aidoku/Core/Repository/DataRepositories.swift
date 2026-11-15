//
//  DataRepositories.swift
//  Aidoku
//
//  SUWA-13 F4: the data layer as one repository per domain, async and with Sendable values, so that screens and
//  services stop using Core Data directly. The Core Data implementation (and `shared`) live in
//  Core/Database/Repository; this folder holds only the contracts (no Core Data, no UIKit).
//  Repositories never post notifications nor touch settings: the services keep doing it after the `await` (D6).
//

/// One repository per domain. Each lot of F4 adds its field here.
struct DataRepositories: Sendable {
    var tracks: any TrackRepository
    /// The few synchronous main-thread reads the reader and the tracker still need (D8; gone in F9/F11).
    var mainActorReads: any MainActorReads

    init(tracks: any TrackRepository, mainActorReads: any MainActorReads) {
        self.tracks = tracks
        self.mainActorReads = mainActorReads
    }
}
