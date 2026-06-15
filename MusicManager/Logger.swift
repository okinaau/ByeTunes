import Foundation
import SwiftUI
import Combine

class Logger: ObservableObject {
    static let shared = Logger()
    
    @Published var logs: String = ""
    private var dateFormatter: DateFormatter
    
    
    private let logQueue = DispatchQueue(label: "com.edualexxis.MusicManager.logger")

    private let suppressedSubstrings: [String] = [
        "[AppleMusicAPI] Fetching token via URLSession...",
        "[AppleMusicAPI] Found JS bundle:",
        "[Download] Requesting http",
        "[Download] Received JSON redirect:",
        "[Download] Resolved manifest media URL:",
        "[Download] Retrying Tidal search host",
        "[Download] Tidal search host ",
        "[Download] Tidal search '",
        "[Download] Retrying Qobuz search host",
        "[Download] Qobuz search host ",
        "[Download] Qobuz search '",
        "[Download] Queued Tidal fallback candidate",
        "[Download] Queued Qobuz fallback candidate",
        "[Download] Trying primary Tidal fallback candidate:",
        "[Download] Trying second-stage Tidal candidate:",
        "[Download] Trying primary Qobuz fallback candidate:",
        "[Download] Trying second-stage Qobuz candidate:",
        "[Download] Matching from Apple metadata",
        "[Download] Matching from iTunes metadata fallback",
        "[Download] Matching from Deezer metadata fallback",
        "[Download] Song.link mapping failed",
        "[Download] Song.link Qobuz mapping failed",
        "[Download] Mapped Tidal URL:",
        "[Download] Mapped Qobuz URL:",
        "[Download] Failed to refresh rotating Tidal API list:",
        "[Download] Failed to map Apple Music track",
        "[Download] Mapped Apple Music source URL",
        "[Download] Using source URL",
        "[Download] ByeTunes Spotify fallback:",
        "[Download] Song.link Deezer mapping failed",
        "[Download] Mapped track to Deezer",
        "[Download] Requesting ByeTunes API",
        "[Download] Album search fell back",
        "[Download] Playlist search is using",
        "[Download] Attempting last-resort Spotify mapping",
        "[Download] Mapped to Spotify for last-resort retry",
        "[Download] Last-resort Spotify mapping failed",
        "[DeviceManager] downloadFileFromDevice called for: /iTunes_Control/iTunes/Artwork/Originals/",
        " bytes from /iTunes_Control/iTunes/Artwork/Originals/",
        "[SongMetadata] Extracted artwork:",
        "[SongMetadata] Deep Scan extracted artwork:",
        "[SongMetadata] Extracted Album Artist:",
        "[SongMetadata] Ignored invalid Album Artist:",
        "[SongMetadata] Extracted year:",
        "[SongMetadata] Extracted and cleaned lyrics",
        "[SongMetadata] Extracted Track via Data:",
        "[SongMetadata] Extracted Disc via Data:",
        "[SongMetadata] Applied FLAC Vorbis fallback metadata",
        "[SongMetadata] Parsed filename",
        "[SongMetadata] M4A release date:",
        "[SongMetadata] M4A year from",
        "[SongMetadata] M4A Apple IDs:",
        "[SongMetadata] Local audio traits detected",
        "[SongMetadata] Successfully fetched lyrics from",
        "[SongMetadata] LRCLIB fetch failed:",
        "[SongMetadata] LRCLIB search failed:",
        "[SongMetadata] Musixmatch search returned no suitable lyric match",
        "[SongMetadata] Musixmatch fallback failed:",
        "[SongMetadata] Musixmatch search failed:",
        "[SongMetadata] Musixmatch lyrics resolve failed:",
        "[SongMetadata] NetEase search returned no suitable lyric match",
        "[SongMetadata] NetEase fallback failed:",
        "[SongMetadata] NetEase search failed:",
        "[SongMetadata] NetEase lyrics resolve failed:",
        "[SongMetadata] Found lyrics from",
        "[SongMetadata] Updated artwork with",
        "[SongMetadata] Searching iTunes for:",
        "[SongMetadata] ✓ Validated match:",
        "[SongMetadata] x Rejected match:",
        "[SongMetadata] No valid iTunes match found after filtering.",
        "[SongMetadata] Searching Deezer for:",
        "[SongMetadata] ✓ Deezer match:",
        "[SongMetadata] Enhanced with Deezer details:",
        "[MusicView] Using enrichment concurrency:",
        "[MusicView] Using import chunk size:",
        "[MusicView] Large import detected."
    ]
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
        log("===========================================")
        log("Logger Initialized")
        log("===========================================")
    }
    
    func log(_ message: String) {
        guard shouldLog(message) else { return }
        let timestamp = dateFormatter.string(from: Date())
        let formattedMessage = "[\(timestamp)] \(message)"
        
        
        print(formattedMessage)
        
        
        logQueue.async {
            DispatchQueue.main.async {
                self.logs.append(formattedMessage + "\n")
            }
        }
    }

    private func shouldLog(_ message: String) -> Bool {
        for fragment in suppressedSubstrings where message.contains(fragment) {
            return false
        }
        return true
    }
    
    func clear() {
        logQueue.async {
            DispatchQueue.main.async {
                self.logs = ""
            }
        }
    }
    
    func saveLogs() -> URL? {
        let fileManager = FileManager.default
        let logsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        let fileURL = logsDirectory.appendingPathComponent("MusicManager_Logs.txt")
        
        do {
            if !fileManager.fileExists(atPath: logsDirectory.path) {
                try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try logs.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("Failed to save logs: \(error)")
            return nil
        }
    }
}
