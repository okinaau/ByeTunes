import Foundation

struct PersistedSong: Codable {
    var localURLPath: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String?
    var genre: String
    var year: Int
    var durationMs: Int
    var fileSize: Int
    var remoteFilename: String
    var artworkData: Data?
    var artworkPreviewData: Data?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var lyrics: String?
    var explicitRating: Int
    var richAppleMetadataFetched: Bool
}

struct PersistedDownloadTrack: Codable {
    var id: String
    var name: String
    var artistLine: String
    var albumName: String
    var artworkURLString: String?
    var isExplicit: Bool
    var sourceURL: String
    var sourceContext: String
    var provider: String
    var artistIdentifier: String?
    var albumIdentifier: String?
    var previewURLString: String?
}

struct PersistedDownloadQueue: Codable {
    var tracksByID: [String: PersistedDownloadTrack]
    var queueOrder: [String]
    var pendingIDs: [String]
    var failedIDs: [String]
    var activeID: String?
    var totalQueueCount: Int
    var completedQueueCount: Int
}

enum QueuePersistenceStore {
    private static let musicQueueKey = "persistedMusicQueue.v1"
    private static let downloadQueueKey = "persistedDownloadQueue.v1"

    @MainActor
    static func saveMusicQueue(_ songs: [SongMetadata]) {
        let persisted = songs.map(PersistedSong.init)
        save(persisted, forKey: musicQueueKey)
    }

    @MainActor
    static func loadMusicQueue() -> [SongMetadata] {
        guard let persisted: [PersistedSong] = load([PersistedSong].self, forKey: musicQueueKey) else {
            return []
        }

        return persisted.compactMap { item in
            let url = URL(fileURLWithPath: item.localURLPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return item.songMetadata(localURL: url)
        }
    }

    static func clearMusicQueue() {
        UserDefaults.standard.removeObject(forKey: musicQueueKey)
    }

    static func saveDownloadQueue(_ queue: PersistedDownloadQueue?) {
        guard let queue else {
            UserDefaults.standard.removeObject(forKey: downloadQueueKey)
            return
        }
        save(queue, forKey: downloadQueueKey)
    }

    static func loadDownloadQueue() -> PersistedDownloadQueue? {
        load(PersistedDownloadQueue.self, forKey: downloadQueueKey)
    }

    static func clearDownloadQueue() {
        UserDefaults.standard.removeObject(forKey: downloadQueueKey)
    }

    private static func save<T: Encodable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            Logger.shared.log("[QueuePersistence] Failed to save \(key): \(error)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Logger.shared.log("[QueuePersistence] Failed to load \(key): \(error)")
            return nil
        }
    }
}

extension PersistedSong {
    @MainActor
    init(song: SongMetadata) {
        self.localURLPath = song.localURL.path
        self.title = song.title
        self.artist = song.artist
        self.album = song.album
        self.albumArtist = song.albumArtist
        self.genre = song.genre
        self.year = song.year
        self.durationMs = song.durationMs
        self.fileSize = song.fileSize
        self.remoteFilename = song.remoteFilename
        self.artworkData = song.artworkData
        self.artworkPreviewData = song.artworkPreviewData
        self.trackNumber = song.trackNumber
        self.trackCount = song.trackCount
        self.discNumber = song.discNumber
        self.discCount = song.discCount
        self.lyrics = song.lyrics
        self.explicitRating = song.explicitRating
        self.richAppleMetadataFetched = song.richAppleMetadataFetched
    }

    @MainActor
    func songMetadata(localURL: URL) -> SongMetadata {
        var song = SongMetadata(
            localURL: localURL,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            year: year,
            durationMs: durationMs,
            fileSize: fileSize,
            remoteFilename: remoteFilename,
            artworkData: artworkData,
            artworkPreviewData: artworkPreviewData,
            trackNumber: trackNumber,
            trackCount: trackCount,
            discNumber: discNumber,
            discCount: discCount,
            lyrics: lyrics
        )
        song.explicitRating = explicitRating
        song.richAppleMetadataFetched = richAppleMetadataFetched
        return song
    }
}

extension PersistedDownloadTrack {
    init(track: DownloadTrack) {
        self.id = track.id
        self.name = track.name
        self.artistLine = track.artistLine
        self.albumName = track.albumName
        self.artworkURLString = track.artworkURL?.absoluteString
        self.isExplicit = track.isExplicit
        self.sourceURL = track.sourceURL
        self.sourceContext = track.sourceContext.persistenceValue
        self.provider = track.provider.rawValue
        self.artistIdentifier = track.artistIdentifier
        self.albumIdentifier = track.albumIdentifier
        self.previewURLString = track.previewURL?.absoluteString
    }

    var downloadTrack: DownloadTrack? {
        guard
            let provider = DownloadView.SearchProvider(rawValue: provider),
            let sourceContext = DownloadTrack.SourceContext(persistenceValue: sourceContext)
        else {
            return nil
        }

        return DownloadTrack(
            id: id,
            name: name,
            artistLine: artistLine,
            albumName: albumName,
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            isExplicit: isExplicit,
            sourceURL: sourceURL,
            sourceContext: sourceContext,
            provider: provider,
            artistIdentifier: artistIdentifier,
            albumIdentifier: albumIdentifier,
            previewURL: previewURLString.flatMap(URL.init(string:))
        )
    }
}

extension DownloadTrack.SourceContext {
    fileprivate var persistenceValue: String {
        switch self {
        case .song: return "song"
        case .album: return "album"
        }
    }

    fileprivate init?(persistenceValue: String) {
        switch persistenceValue {
        case "song": self = .song
        case "album": self = .album
        default: return nil
        }
    }
}
