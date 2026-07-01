// PlaylistExporter.swift
// .m3u8 playlist export/import for ByeTunes (Issue #65)

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

/// A single track's identity as recorded in the exported file.
private struct M3UTrackEntry {
    let title: String
    let artist: String
    let album: String
}

final class PlaylistExporter {

    // MARK: - Export

    /// Exports a playlist already present in the on-device library as a `.m3u8` file.
    @discardableResult
    static func exportPlaylist(
        existingDbData: Data,
        playlistName: String,
        toFileURL destinationURL: URL
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

        Logger.shared.log("[PlaylistExporter] Exported \(tracks.count) tracks for playlist '\(playlistName)'")
        return tracks.count
    }

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

    private static func generateM3U8Content(playlistName: String, tracks: [M3UTrackEntry]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(playlistName)"]
        for track in tracks {
            let safeTitle = track.title.replacingOccurrences(of: "\n", with: " ")
            let safeArtist = track.artist.replacingOccurrences(of: "\n", with: " ")
            let safeAlbum = track.album.replacingOccurrences(of: "\n", with: " ")
            lines.append("#EXTINF:-1,\(safeTitle) - \(safeArtist)")
            lines.append("#EXTALB:\(safeAlbum)")
            lines.append("# \(safeTitle)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Import

    /// Parses a `.m3u8` file and rebuilds the playlist in the on-device library database.
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

        // Calls the method we just un-privatized in MediaLibraryBuilder
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
                let afterComma = line.split(separator: ",", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                let parts = afterComma.components(separatedBy: " - ")
                pendingTitle = parts.first
                pendingArtist = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : ""
                if pendingTitle == nil { continue }
            } else if line.hasPrefix("#EXTALB:") {
                let album = String(line.dropFirst("#EXTALB:".count))
                if let title = pendingTitle {
                    entries.append(M3UTrackEntry(title: title, artist: pendingArtist ?? "", album: album))
                    pendingTitle = nil
                    pendingArtist = nil
                }
            } else if !line.hasPrefix("#"), let title = pendingTitle {
                entries.append(M3UTrackEntry(title: title, artist: pendingArtist ?? "", album: ""))
                pendingTitle = nil
                pendingArtist = nil
            }
        }
        return (playlistName, entries)
    }
}
