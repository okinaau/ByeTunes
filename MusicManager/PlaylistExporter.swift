// PlaylistExporter.swift
// .m3u8 playlist export/import for ByeTunes (issue #65)
//
// DESIGN NOTES — read before wiring this up:
//
// 1. No `import MediaLibraryBuilder`. MediaLibraryBuilder is a class in this
//    same app target, not a separate module — Swift types in the same target
//    need no import at all. (That phantom import was the entire cause of the
//    original build failure.)
//
// 2. Calling convention mirrors MediaLibraryBuilder.addSongsToExistingDatabase:
//    callers pass in the on-device MediaLibrary.sqlitedb as Data, this file
//    does the local sqlite work, and hands back Data for whatever existing
//    code already pushes files to the device over the LocalDevVPN/RPPairing
//    tunnel — the same path Light Backup / Full Backup already use. I don't
//    have visibility into that transfer layer, so this mirrors the one
//    pattern in the codebase that's proven to work rather than inventing a
//    new one.
//
// 3. Matching uses MediaLibraryBuilder.getExistingSongSignatures(db:), the
//    exact "title|artist|album" identity the rest of the app already uses to
//    decide "is this the same song" — NOT file path, which will not survive
//    a wipe + re-inject cycle (fresh container/location values get assigned
//    every time). REQUIRES ONE CHANGE in MediaLibraryBuilder.swift:
//
//        private static func getExistingSongSignatures(...)
//    →   static func getExistingSongSignatures(...)
//
//    (just drop `private` — no behavior change, just visibility.)
//
// 4. Playlist artwork: the sidecar `.png` file is saved on export and read
//    back on import, but it is NOT yet written into the database as playlist
//    artwork. Doing that needs the correct `entity_type` value this schema
//    uses for containers, which isn't established anywhere in the code I've
//    seen (only item/album/artist entity types show up). Guessing at that
//    risks silently attaching artwork to the wrong entity. Treat this as a
//    follow-up once that value is confirmed (e.g. by setting playlist artwork
//    from the Music app and inspecting what entity_type gets written).

import Foundation
import SQLite3

enum PlaylistExporterError: Error, LocalizedError {
    case invalidInput
    case databaseOpenFailed
    case fileReadFailed
    case noMatchingSongs
    case playlistNotFound

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Playlist name or track list was empty."
        case .databaseOpenFailed:
            return "Could not open the media library database."
        case .fileReadFailed:
            return "Could not read the .m3u8 file."
        case .noMatchingSongs:
            return "None of the tracks in this playlist file could be matched to songs currently in your library."
        case .playlistNotFound:
            return "Could not find that playlist in the library database."
        }
    }
}

/// A single track's identity as recorded in the exported file — enough to
/// re-match it after a full library wipe, when the original item_pid and
/// file path no longer exist.
private struct M3UTrackEntry {
    let title: String
    let artist: String
    let album: String
}

final class PlaylistExporter {

    // MARK: - Export

    /// Exports a playlist already present in the on-device library as a
    /// `.m3u8` file, with an optional sidecar artwork image.
    ///
    /// - Parameters:
    ///   - existingDbData: raw bytes of the on-device MediaLibrary.sqlitedb
    ///     (same blob passed to MediaLibraryBuilder.addSongsToExistingDatabase)
    ///   - playlistName: exact name of the playlist container to export
    ///   - destinationURL: where to write the `.m3u8` file
    ///   - artworkData: optional playlist artwork to save as a PNG sidecar
    ///     next to the .m3u8 file (caller supplies the bytes — this file has
    ///     no way to independently know where playlist artwork lives)
    /// - Returns: number of tracks written
    @discardableResult
    static func exportPlaylist(
        existingDbData: Data,
        playlistName: String,
        toFileURL destinationURL: URL,
        artworkData: Data? = nil
    ) throws -> Int {
        guard !playlistName.isEmpty else {
            throw PlaylistExporterError.invalidInput
        }

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistExport-\(UUID().uuidString).sqlitedb")
        try existingDbData.write(to: dbPath)
        defer { try? FileManager.default.removeItem(at: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            throw PlaylistExporterError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        guard let containerPid = MediaLibraryBuilder.getPlaylists(db: db)
            .first(where: { $0.name == playlistName })?.pid else {
            throw PlaylistExporterError.playlistNotFound
        }

        let tracks = orderedTracks(inContainer: containerPid, db: db)
        guard !tracks.isEmpty else {
            throw PlaylistExporterError.noMatchingSongs
        }

        let m3uContent = generateM3U8Content(playlistName: playlistName, tracks: tracks)
        try m3uContent.write(to: destinationURL, atomically: true, encoding: .utf8)

        if let artworkData {
            let sidecarURL = destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(playlistName).png")
            try artworkData.write(to: sidecarURL)
        }

        Logger.shared.log("[PlaylistExporter] Exported \(tracks.count) tracks for playlist '\(playlistName)'")
        return tracks.count
    }

    /// Reads a container's tracks in stored position order, joined against
    /// item_extra / item_artist / album for the metadata needed to re-match
    /// them later. Mirrors the join shape MediaLibraryBuilder itself uses in
    /// getExistingSongSignatures, just filtered to one container.
    private static func orderedTracks(inContainer containerPid: Int64, db: OpaquePointer?) -> [M3UTrackEntry] {
        var tracks: [M3UTrackEntry] = []
        let query = """
            SELECT item_extra.title, item_artist.item_artist, album.album
            FROM container_item
            JOIN item ON container_item.item_pid = item.item_pid
            LEFT JOIN item_extra ON item.item_pid = item_extra.item_pid
            LEFT JOIN item_artist ON item.item_artist_pid = item_artist.item_artist_pid
            LEFT JOIN album ON item.album_pid = album.album_pid
            WHERE container_item.container_pid = ?
            ORDER BY container_item.position ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, containerPid)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let artist = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let album = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            guard !title.isEmpty else { continue }
            tracks.append(M3UTrackEntry(title: title, artist: artist, album: album))
        }
        return tracks
    }

    /// Builds extended-M3U content. Beyond the standard `#EXTINF` line this
    /// adds a non-standard `#EXTALB` comment carrying the album name — title
    /// + artist alone is ambiguous for compilations/covers, and the file path
    /// a normal .m3u would store cannot be trusted to survive a wipe +
    /// re-inject cycle. Standards-compliant M3U players ignore unrecognized
    /// `#` lines, so this stays a valid, playable playlist file too.
    private static func generateM3U8Content(playlistName: String, tracks: [M3UTrackEntry]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(playlistName)"]
        for track in tracks {
            let safeTitle = track.title.replacingOccurrences(of: "\n", with: " ")
            let safeArtist = track.artist.replacingOccurrences(of: "\n", with: " ")
            let safeAlbum = track.album.replacingOccurrences(of: "\n", with: " ")
            lines.append("#EXTINF:-1,\(safeTitle) - \(safeArtist)")
            lines.append("#EXTALB:\(safeAlbum)")
            // No usable file path survives a wipe/re-inject cycle, so the
            // track identity is recorded as a comment rather than a
            // soon-to-be-stale path.
            lines.append("# \(safeTitle)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Import

    /// Parses a `.m3u8` file written by `exportPlaylist` and rebuilds the
    /// playlist in the on-device library database, matching each entry by
    /// title/artist/album against whatever is currently in the library
    /// (typically freshly re-injected via ByeTunes' normal flow first).
    ///
    /// - Parameters:
    ///   - existingDbData: raw bytes of the on-device MediaLibrary.sqlitedb
    ///   - fileURL: the `.m3u8` file to import
    ///   - playlistName: name for the (re)created playlist; defaults to the
    ///     file's own `#PLAYLIST:` line, falling back to the file's name
    /// - Returns: updated database bytes to hand to whatever already pushes
    ///   files back to the device (same pattern MediaLibraryBuilder returns),
    ///   how many tracks matched, and titles that didn't match (for UI
    ///   feedback — e.g. "12 of 14 tracks restored")
    static func importPlaylist(
        existingDbData: Data,
        fromFileURL fileURL: URL,
        playlistName: String? = nil
    ) throws -> (updatedDbData: Data, matchedCount: Int, unmatchedTitles: [String]) {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw PlaylistExporterError.fileReadFailed
        }

        let (parsedName, entries) = parseM3U8(content)
        guard !entries.isEmpty else {
            throw PlaylistExporterError.invalidInput
        }
        let resolvedName = playlistName ?? parsedName ?? fileURL.deletingPathExtension().lastPathComponent

        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistImport-\(UUID().uuidString).sqlitedb")
        try existingDbData.write(to: dbPath)
        defer { try? FileManager.default.removeItem(at: dbPath) }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else {
            throw PlaylistExporterError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        // Requires getExistingSongSignatures to be non-private — see the
        // note at the top of this file.
        let signatures = MediaLibraryBuilder.getExistingSongSignatures(db: db)

        var matchedPids: [Int64] = []
        var unmatchedTitles: [String] = []
        for entry in entries {
            let signature = "\(entry.title)|\(entry.artist)|\(entry.album)"
            if let pid = signatures[signature] {
                matchedPids.append(pid)
            } else {
                unmatchedTitles.append(entry.title)
            }
        }

        guard !matchedPids.isEmpty else {
            throw PlaylistExporterError.noMatchingSongs
        }

        // If a playlist with this name already exists, append to it —
        // this is a best-effort path for "add these back into an existing
        // playlist" and does not re-sequence pre-existing entries. The
        // primary use case (restoring after a full wipe) always hits
        // createPlaylist below, since the wipe removes the container too.
        if let existingPid = MediaLibraryBuilder.getPlaylists(db: db)
            .first(where: { $0.name == resolvedName })?.pid {
            try MediaLibraryBuilder.addToPlaylist(db: db, containerPid: existingPid, songPids: matchedPids)
        } else {
            try MediaLibraryBuilder.createPlaylist(db: db, playlistName: resolvedName, songPids: matchedPids)
        }

        Logger.shared.log("[PlaylistExporter] Import '\(resolvedName)': matched \(matchedPids.count)/\(entries.count) tracks")

        let updatedData = try Data(contentsOf: dbPath)
        return (updatedData, matchedPids.count, unmatchedTitles)
    }

    /// Parses the extended-M3U format written by `generateM3U8Content`. Also
    /// tolerant of a plain/foreign `.m3u` (no #EXTALB lines) — those entries
    /// just get an empty album, which weakens matching but doesn't crash.
    private static func parseM3U8(_ content: String) -> (playlistName: String?, entries: [M3UTrackEntry]) {
        var playlistName: String?
        var entries: [M3UTrackEntry] = []
        var pendingTitle: String?
        var pendingArtist: String?

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#PLAYLIST:") {
                playlistName = String(line.dropFirst("#PLAYLIST:".count))
            } else if line.hasPrefix("#EXTINF:") {
                // "#EXTINF:-1,Title - Artist" -> split on the FIRST comma to
                // isolate "Title - Artist", then split that on " - ".
                let afterComma = line.split(separator: ",", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                let parts = afterComma.components(separatedBy: " - ")
                pendingTitle = parts.first
                pendingArtist = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : ""
                if pendingTitle == nil { continue }
                // No #EXTALB will follow on a foreign .m3u — flush here with
                // an empty album so the entry isn't silently dropped.
            } else if line.hasPrefix("#EXTALB:") {
                let album = String(line.dropFirst("#EXTALB:".count))
                if let title = pendingTitle {
                    entries.append(M3UTrackEntry(title: title, artist: pendingArtist ?? "", album: album))
                    pendingTitle = nil
                    pendingArtist = nil
                }
            } else if !line.hasPrefix("#"), let title = pendingTitle {
                // A real path line with no #EXTALB in between (foreign .m3u) —
                // flush what we have with an empty album.
                entries.append(M3UTrackEntry(title: title, artist: pendingArtist ?? "", album: ""))
                pendingTitle = nil
                pendingArtist = nil
            }
        }
        return (playlistName, entries)
    }
}
