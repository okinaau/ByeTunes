import SwiftUI
import Combine
import UIKit
import CryptoKit
import AVFoundation
import CommonCrypto

struct DownloadView: View {
    private enum ResultsPage: String {
        case songs = "Songs"
        case albums = "Albums"
        case playlists = "Playlists"
    }

    enum SearchProvider: String, CaseIterable, Identifiable {
        case appleMusic
        case spotify
        case tidal
        case metadata

        static var allCases: [SearchProvider] {
            [.appleMusic, .spotify, .metadata]
        }

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appleMusic: return "Apple Music"
            case .spotify: return "Spotify"
            case .tidal: return "Tidal"
            case .metadata: return "iTunes + Deezer"
            }
        }

        var searchPlaceholder: String {
            switch self {
            case .appleMusic: return "Search or paste an Apple Music link"
            case .spotify: return "Search or paste a Spotify link"
            case .tidal: return "Search Tidal songs"
            case .metadata: return "Search iTunes and Deezer"
            }
        }

        var emptyStateSubtitle: String {
            switch self {
            case .appleMusic: return "Search a song and tap download"
            case .spotify: return "Search a song and tap download"
            case .tidal: return "Search Tidal and tap download"
            case .metadata: return "Search iTunes and Deezer and tap download"
            }
        }
    }

    private struct AlbumSelectionState {
        var album: DownloadAlbum?
        var tracks: [DownloadTrack] = []
        var selectedTrackIDs: Set<String> = []
        var isLoading = false
        var errorText: String?
        var navigationTitle = "Album Download"
        var helperText = "Choose the tracks you want to download, or grab the full album in one tap."

        var isPresented: Bool { album != nil }
        var selectedTracks: [DownloadTrack] {
            tracks.filter { selectedTrackIDs.contains($0.id) }
        }
    }

    private struct DirectTrackSelectionState: Identifiable {
        let id = UUID()
        let track: DownloadTrack
    }

    @Binding var songs: [SongMetadata]
    @Binding var status: String
    @StateObject private var vm = DownloadViewModel()
    @AppStorage("downloadSearchProvider") private var searchProviderRaw = SearchProvider.appleMusic.rawValue
    @State private var query = ""
    @State private var handledEmittedCount = 0
    @State private var selectedPage: ResultsPage = .songs
    @State private var showingQueueDetails = false
    @State private var albumSelection = AlbumSelectionState()
    @State private var directTrackSelection: DirectTrackSelectionState?
    @State private var selectedTrackForBrowse: DownloadTrack?
    @State private var pushedArtist: DownloadArtist?

    private var usesFloatingTabBarLayout: Bool {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return (16...18).contains(major)
    }

    private var resultsBottomInset: CGFloat {
        usesFloatingTabBarLayout ? 110 : 24
    }

    private var searchProvider: SearchProvider {
        get {
            guard let provider = SearchProvider(rawValue: searchProviderRaw) else {
                return .appleMusic
            }
            return provider == .tidal ? .appleMusic : provider
        }
        nonmutating set { searchProviderRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Download")
                        .font(.system(size: 34, weight: .bold))
                    Spacer()
                    Button {
                        showingQueueDetails = true
                    } label: {
                        DownloadQueueIndicator(
                            progress: vm.currentSongProgress,
                            label: vm.queueCounterText
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 0)
                .padding(.horizontal, 20)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(searchProvider.searchPlaceholder, text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit {
                            Task { await vm.search(query: query, provider: searchProvider) }
                        }

                    if vm.isSearching {
                        ProgressView()
                            .scaleEffect(0.9)
                    } else if !query.isEmpty {
                        Button {
                            query = ""
                            vm.artistResults = []
                            vm.songResults = []
                            vm.albumResults = []
                            vm.playlistResults = []
                            vm.canLoadMoreSongs = false
                            vm.canLoadMoreAlbums = false
                            vm.canLoadMorePlaylists = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 20)
                if let error = vm.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                HStack {
                    Text("Results")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if !vm.songResults.isEmpty || !vm.albumResults.isEmpty || !vm.playlistResults.isEmpty {
                        Text(resultsSummaryText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 20)

                if vm.songResults.isEmpty && vm.albumResults.isEmpty && vm.playlistResults.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 48, weight: .light))
                            .foregroundColor(Color(.systemGray3))
                        VStack(spacing: 4) {
                            Text("No results yet")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text(searchProvider.emptyStateSubtitle)
                                .font(.subheadline)
                                .foregroundColor(Color(.systemGray))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            pageSwitcher

                            if selectedPage == .songs {
                                if vm.songResults.isEmpty {
                                    emptyPage("No songs", subtitle: "No song matches for this search")
                                } else {
                                    ForEach(Array(vm.songResults.enumerated()), id: \.element.id) { index, track in
                                        songRow(track)
                                        if index < vm.songResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                    if vm.canLoadMoreSongs {
                                        Divider().padding(.leading, 80)
                                        loadMoreButton(title: "Load More Songs", isLoading: vm.isLoadingMoreSongs) {
                                            Task { await vm.loadMoreSongs() }
                                        }
                                    }
                                }
                            } else if selectedPage == .albums {
                                if vm.albumResults.isEmpty {
                                    emptyPage("No albums", subtitle: "No album matches for this search")
                                } else {
                                    ForEach(Array(vm.albumResults.enumerated()), id: \.element.id) { index, album in
                                        albumRow(album)
                                        if index < vm.albumResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                    if vm.canLoadMoreAlbums {
                                        Divider().padding(.leading, 80)
                                        loadMoreButton(title: "Load More Albums", isLoading: vm.isLoadingMoreAlbums) {
                                            Task { await vm.loadMoreAlbums() }
                                        }
                                    }
                                }
                            } else {
                                if vm.playlistResults.isEmpty {
                                    emptyPage("No playlists", subtitle: "No playlist matches for this search")
                                } else {
                                    ForEach(Array(vm.playlistResults.enumerated()), id: \.element.id) { index, playlist in
                                        playlistRow(playlist)
                                        if index < vm.playlistResults.count - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                    if vm.canLoadMorePlaylists {
                                        Divider().padding(.leading, 80)
                                        loadMoreButton(title: "Load More Playlists", isLoading: vm.isLoadingMorePlaylists) {
                                            Task { await vm.loadMorePlaylists() }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, resultsBottomInset)
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
        }
        .onChange(of: vm.emittedSongs.count) { newCount in
            guard newCount > handledEmittedCount else { return }
            for idx in handledEmittedCount..<newCount {
                let song = vm.emittedSongs[idx]
                songs.append(song)
                status = "Downloaded: \(song.title)"
            }
            handledEmittedCount = newCount
        }
        .onAppear {
            if searchProviderRaw == SearchProvider.tidal.rawValue {
                searchProviderRaw = SearchProvider.appleMusic.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("IncomingMusicLink"))) { notification in
            if let link = notification.object as? String {
                self.query = link
                Task {
                    await vm.search(query: link, provider: searchProvider)
                }
            }
        }
        .onChange(of: searchProviderRaw) { newValue in
            vm.artistResults = []
            vm.songResults = []
            vm.albumResults = []
            vm.playlistResults = []
            selectedPage = .songs
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let provider = SearchProvider(rawValue: newValue) ?? .appleMusic
            Task { await vm.search(query: query, provider: provider) }
        }
        .onChange(of: vm.pendingDirectLinkAction?.id) { _ in
            guard let action = vm.pendingDirectLinkAction else { return }
            switch action.payload {
            case .track(let track):
                directTrackSelection = DirectTrackSelectionState(track: track)
            case .collection(let album, let tracks, let title, let helperText):
                presentResolvedCollectionSelection(
                    album: album,
                    tracks: tracks,
                    navigationTitle: title,
                    helperText: helperText
                )
            case .artist(let artist):
                presentArtistSelection(for: artist)
            }
            vm.pendingDirectLinkAction = nil
        }
        .sheet(isPresented: $showingQueueDetails) {
            DownloadQueueDetailsSheet(vm: vm)
        }
        .sheet(
            isPresented: Binding(
                get: { albumSelection.isPresented },
                set: { isPresented in
                    if !isPresented { resetAlbumSelection() }
                }
            )
        ) {
            albumSelectionSheet
        }
        .sheet(item: $directTrackSelection) { selection in
            DirectTrackDownloadSheet(
                track: selection.track,
                state: vm.state(for: selection.track.id),
                onCancel: {
                    directTrackSelection = nil
                },
                onConfirm: {
                    if vm.state(for: selection.track.id) == .failed {
                        vm.retry(trackID: selection.track.id)
                    } else {
                        vm.enqueue(track: selection.track)
                    }
                    directTrackSelection = nil
                }
            )
        }
        .sheet(item: $selectedTrackForBrowse) { track in
            TrackBrowseSheet(
                track: track,
                onSelectAlbum: {
                    selectedTrackForBrowse = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        presentAlbumSelection(for: albumForTrack(track))
                    }
                },
                onSelectArtist: {
                    selectedTrackForBrowse = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        presentArtistSelection(for: track)
                    }
                }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $pushedArtist) { artist in
            NavigationStack {
                ArtistProfileScreen(
                    artist: artist,
                    vm: vm,
                    onSelectAlbum: { album in
                        presentAlbumSelection(for: album)
                    },
                    onBrowseTrack: { track in
                        selectedTrackForBrowse = track
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                 .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var pageSwitcher: some View {
        HStack(spacing: 8) {
            Button {
                selectedPage = .songs
            } label: {
                VStack(spacing: 6) {
                    Text("Songs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedPage == .songs ? .primary : .secondary)

                    Rectangle()
                        .fill(selectedPage == .songs ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                        .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .buttonStyle(.plain)

            Button {
                selectedPage = .albums
            } label: {
                VStack(spacing: 6) {
                    Text("Albums")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedPage == .albums ? .primary : .secondary)

                    Rectangle()
                        .fill(selectedPage == .albums ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                        .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .buttonStyle(.plain)

            Button {
                selectedPage = .playlists
            } label: {
                VStack(spacing: 6) {
                    Text("Playlists")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedPage == .playlists ? .primary : .secondary)

                    Rectangle()
                        .fill(selectedPage == .playlists ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                        .clipShape(Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func emptyPage(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color(.systemGray))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var resultsSummaryText: String {
        "\(vm.songResults.count) songs • \(vm.albumResults.count) albums • \(vm.playlistResults.count) playlists"
    }

    @ViewBuilder
    private func loadMoreButton(title: String, isLoading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.9)
                }
                Text(isLoading ? "Loading..." : title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    @ViewBuilder
    private func songRow(_ track: DownloadTrack) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedTrackForBrowse = track
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: track.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color(.tertiarySystemFill)
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .lineLimit(1)
                            .font(.headline)
                        HStack(spacing: 6) {
                            Text(track.artistLine)
                                .lineLimit(1)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if track.isExplicit {
                                Text("E")
                                    .font(.system(size: 8, weight: .black))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .foregroundColor(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        Text(track.albumName)
                            .lineLimit(1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                vm.togglePreview(for: track)
            } label: {
                if vm.isPreviewLoading(for: track.id) {
                    ProgressView()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: vm.isPreviewPlaying(for: track.id) ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(vm.isPreviewPlaying(for: track.id) ? .blue : .secondary)
                }
            }
            .buttonStyle(.plain)

            Button {
                if vm.state(for: track.id) == .failed {
                    vm.retry(trackID: track.id)
                } else {
                    vm.enqueue(track: track)
                }
            } label: {
                switch vm.state(for: track.id) {
                case .downloading:
                    ProgressView().frame(width: 28, height: 28)
                case .queued:
                    Image(systemName: "clock.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                case .idle:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!vm.canEnqueue(trackID: track.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func albumRow(_ album: DownloadAlbum) -> some View {
        HStack(spacing: 12) {
            Button {
                presentAlbumSelection(for: album)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: album.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color(.tertiarySystemFill)
                                Image(systemName: "rectangle.stack.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.name)
                            .lineLimit(1)
                            .font(.headline)
                        Text(album.artistLine)
                            .lineLimit(1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if vm.state(forAlbumID: album.id) == .failed {
                    Task { await vm.retry(album: album) }
                } else {
                    presentAlbumSelection(for: album)
                }
            } label: {
                if vm.isResolvingAlbum(albumID: album.id) {
                    ProgressView().frame(width: 28, height: 28)
                } else {
                    switch vm.state(forAlbumID: album.id) {
                    case .downloading:
                        ProgressView().frame(width: 28, height: 28)
                    case .queued:
                        Image(systemName: "clock.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    case .idle:
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isResolvingAlbum(albumID: album.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var albumSelectionSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let album = albumSelection.album {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            AsyncImage(url: album.artworkURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    ZStack {
                                        Color(.tertiarySystemFill)
                                        Image(systemName: "rectangle.stack.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.name)
                                    .font(.headline.weight(.semibold))
                                    .lineLimit(2)
                                Text(album.artistLine)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }

                        Text(albumSelection.helperText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button("Select All") {
                                albumSelection.selectedTrackIDs = Set(albumSelection.tracks.map(\.id))
                            }
                            .font(.caption.weight(.semibold))

                            Button("Clear All") {
                                albumSelection.selectedTrackIDs.removeAll()
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                            Spacer()

                            if !albumSelection.tracks.isEmpty {
                                Text("\(albumSelection.selectedTrackIDs.count) of \(albumSelection.tracks.count) selected")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                    if let errorText = albumSelection.errorText {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 10)
                    }

                    Group {
                        if albumSelection.isLoading {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Loading album tracks...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if albumSelection.tracks.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 36, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text("No tracks found")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                VStack(spacing: 10) {
                                    ForEach(Array(albumSelection.tracks.enumerated()), id: \.element.id) { index, track in
                                        Button {
                                            toggleAlbumTrackSelection(track)
                                        } label: {
                                            HStack(alignment: .top, spacing: 12) {
                                                ZStack {
                                                    Circle()
                                                        .fill(albumSelection.selectedTrackIDs.contains(track.id) ? Color.accentColor : Color(.systemGray5))
                                                        .frame(width: 24, height: 24)

                                                    Image(systemName: albumSelection.selectedTrackIDs.contains(track.id) ? "checkmark" : "\(index + 1)")
                                                        .font(.system(size: albumSelection.selectedTrackIDs.contains(track.id) ? 11 : 10, weight: .bold))
                                                        .foregroundStyle(albumSelection.selectedTrackIDs.contains(track.id) ? .white : .secondary)
                                                }
                                                .padding(.top, 1)

                                                VStack(alignment: .leading, spacing: 5) {
                                                    HStack(spacing: 6) {
                                                        Text(track.name)
                                                            .font(.subheadline.weight(.semibold))
                                                            .foregroundStyle(.primary)
                                                            .multilineTextAlignment(.leading)
                                                        if track.isExplicit {
                                                            Text("E")
                                                                .font(.system(size: 8, weight: .black))
                                                                .padding(.horizontal, 4)
                                                                .padding(.vertical, 2)
                                                                .background(Color.red)
                                                                .foregroundColor(.white)
                                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                                        }
                                                    }

                                                    Text(track.artistLine)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .multilineTextAlignment(.leading)
                                                }

                                                Spacer()
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(12)
                                            .background(Color(.secondarySystemGroupedBackground))
                                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.bottom, 10)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            queueEntireAlbumAndDismiss()
                        } label: {
                            Text("Download All")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.systemGray5))
                                .foregroundColor(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(albumSelection.isLoading || albumSelection.tracks.isEmpty)

                        Button {
                            queueSelectedAlbumTracksAndDismiss()
                        } label: {
                            Text("Download Selected")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(albumSelection.isLoading || albumSelection.selectedTrackIDs.isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(albumSelection.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resetAlbumSelection()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func presentAlbumSelection(for album: DownloadAlbum) {
        albumSelection = AlbumSelectionState(
            album: album,
            tracks: [],
            selectedTrackIDs: [],
            isLoading: true,
            errorText: nil,
            navigationTitle: "Album Download",
            helperText: "Choose the tracks you want to download, or grab the full album in one tap."
        )

        Task {
            let tracks = await vm.loadTracks(for: album)
            guard albumSelection.album?.id == album.id else { return }

            albumSelection.tracks = tracks
            albumSelection.selectedTrackIDs = Set(tracks.map(\.id))
            albumSelection.isLoading = false
            albumSelection.errorText = tracks.isEmpty ? "Could not load tracks for \(album.name)." : nil
        }
    }

    private func presentPlaylistSelection(for playlist: DownloadAlbum) {
        albumSelection = AlbumSelectionState(
            album: playlist,
            tracks: [],
            selectedTrackIDs: [],
            isLoading: true,
            errorText: nil,
            navigationTitle: "Playlist Download",
            helperText: "Choose the songs you want to download, or grab the full playlist in one tap."
        )

        Task {
            let tracks = await vm.loadTracks(forPlaylist: playlist)
            guard albumSelection.album?.id == playlist.id else { return }

            albumSelection.tracks = tracks
            albumSelection.selectedTrackIDs = Set(tracks.map(\.id))
            albumSelection.isLoading = false
            albumSelection.errorText = tracks.isEmpty ? "Could not load tracks for \(playlist.name)." : nil
        }
    }

    private func presentResolvedCollectionSelection(
        album: DownloadAlbum,
        tracks: [DownloadTrack],
        navigationTitle: String,
        helperText: String
    ) {
        albumSelection = AlbumSelectionState(
            album: album,
            tracks: tracks,
            selectedTrackIDs: Set(tracks.map(\.id)),
            isLoading: false,
            errorText: tracks.isEmpty ? "Could not load tracks for \(album.name)." : nil,
            navigationTitle: navigationTitle,
            helperText: helperText
        )
    }

    private func presentArtistSelection(for track: DownloadTrack) {
        let artist = DownloadArtist(
            id: track.artistIdentifier ?? "\(track.provider.rawValue):\(DownloadSupport.normalizedSearchValue(primaryArtistName(from: track.artistLine)))",
            name: primaryArtistName(from: track.artistLine),
            provider: track.provider,
            artworkURL: track.artworkURL
        )
        presentArtistSelection(for: artist)
    }

    private func presentArtistSelection(for album: DownloadAlbum) {
        let artist = DownloadArtist(
            id: album.artistIdentifier ?? "\(album.provider.rawValue):\(DownloadSupport.normalizedSearchValue(primaryArtistName(from: album.artistLine)))",
            name: primaryArtistName(from: album.artistLine),
            provider: album.provider,
            artworkURL: album.artworkURL
        )
        presentArtistSelection(for: artist)
    }

    private func presentArtistSelection(for artist: DownloadArtist) {
        pushedArtist = artist
    }

    private func toggleAlbumTrackSelection(_ track: DownloadTrack) {
        if albumSelection.selectedTrackIDs.contains(track.id) {
            albumSelection.selectedTrackIDs.remove(track.id)
        } else {
            albumSelection.selectedTrackIDs.insert(track.id)
        }
    }

    private func queueEntireAlbumAndDismiss() {
        guard let album = albumSelection.album else { return }
        let added = vm.enqueue(tracks: albumSelection.tracks, albumID: album.id)
        if added == 0 {
            vm.errorText = "All tracks from \(album.name) are already queued or downloaded."
        }
        resetAlbumSelection()
    }

    private func queueSelectedAlbumTracksAndDismiss() {
        guard let album = albumSelection.album else { return }
        let selectedTracks = albumSelection.selectedTracks
        let added = vm.enqueue(tracks: selectedTracks, albumID: album.id)
        if added == 0 {
            vm.errorText = selectedTracks.isEmpty
                ? "No tracks selected for \(album.name)."
                : "Selected tracks from \(album.name) are already queued or downloaded."
        }
        resetAlbumSelection()
    }

    private func resetAlbumSelection() {
        albumSelection = AlbumSelectionState()
    }

    private func albumForTrack(_ track: DownloadTrack) -> DownloadAlbum {
        DownloadAlbum(
            id: track.albumIdentifier ?? "\(track.provider.rawValue)-album-\(DownloadSupport.normalizedSearchValue(track.artistLine))-\(DownloadSupport.normalizedSearchValue(track.albumName))",
            name: track.albumName,
            artistLine: track.artistLine,
            artworkURL: track.artworkURL,
            sourceURL: track.sourceURL,
            provider: track.provider,
            artistIdentifier: track.artistIdentifier,
            albumIdentifier: track.albumIdentifier
        )
    }

    @ViewBuilder
    private func playlistRow(_ playlist: DownloadAlbum) -> some View {
        HStack(spacing: 12) {
            Button {
                presentPlaylistSelection(for: playlist)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: playlist.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color(.tertiarySystemFill)
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .lineLimit(1)
                            .font(.headline)
                        Text(playlist.artistLine)
                            .lineLimit(1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if vm.state(forAlbumID: playlist.id) == .failed {
                    Task { await vm.retry(playlist: playlist) }
                } else {
                    presentPlaylistSelection(for: playlist)
                }
            } label: {
                if vm.isResolvingAlbum(albumID: playlist.id) {
                    ProgressView().frame(width: 28, height: 28)
                } else {
                    switch vm.state(forAlbumID: playlist.id) {
                    case .downloading:
                        ProgressView().frame(width: 28, height: 28)
                    case .queued:
                        Image(systemName: "clock.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.red)
                    case .idle:
                        Image(systemName: "music.note.list")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(vm.isResolvingAlbum(albumID: playlist.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func primaryArtistName(from artistLine: String) -> String {
        let separatorsPattern = #"\s*(?:,|&| x | y | feat\.?|ft\.?|with)\s*"#
        let canonicalized = artistLine.replacingOccurrences(of: separatorsPattern, with: ",", options: .regularExpression)
        let primary = canonicalized
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (primary?.isEmpty == false) ? primary! : artistLine
    }
}

#Preview {
    DownloadView(songs: .constant([]), status: .constant("Ready"))
}

private struct TrackBrowseSheet: View {
    let track: DownloadTrack
    let onSelectAlbum: () -> Void
    let onSelectArtist: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Color(.systemGray4))
                .frame(width: 38, height: 5)
                .padding(.top, 8)

            HStack(spacing: 12) {
                AsyncImage(url: track.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            Color(.tertiarySystemFill)
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.artistLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(track.albumName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 20)

            VStack(spacing: 12) {
                Button {
                    onSelectAlbum()
                } label: {
                    Label("Go to Album", systemImage: "rectangle.stack")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    onSelectArtist()
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

private struct DirectTrackDownloadSheet: View {
    let track: DownloadTrack
    let state: DownloadTrackState
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    AsyncImage(url: track.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color(.tertiarySystemFill)
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.name)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Text(track.artistLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(track.albumName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                Text("Download this song now?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    Button("Cancel", action: onCancel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(.systemGray5))
                        .foregroundColor(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button(action: onConfirm) {
                        Text(confirmButtonTitle)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(!canConfirm)
                }
            }
            .padding(20)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Song Download")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }

    private var canConfirm: Bool {
        switch state {
        case .queued, .downloading, .done:
            return false
        case .idle, .failed:
            return true
        }
    }

    private var confirmButtonTitle: String {
        switch state {
        case .failed:
            return "Retry Download"
        case .queued:
            return "Already Queued"
        case .downloading:
            return "Downloading"
        case .done:
            return "Already Downloaded"
        case .idle:
            return "Download"
        }
    }
}

struct DownloadTrack: Identifiable {
    enum SourceContext {
        case song
        case album
    }

    let id: String
    let name: String
    let artistLine: String
    let albumName: String
    let artworkURL: URL?
    let isExplicit: Bool
    let sourceURL: String
    let sourceContext: SourceContext
    let provider: DownloadView.SearchProvider
    let artistIdentifier: String?
    let albumIdentifier: String?
    let previewURL: URL?
}

struct DownloadAlbum: Identifiable {
    let id: String
    let name: String
    let artistLine: String
    let artworkURL: URL?
    let sourceURL: String
    let provider: DownloadView.SearchProvider
    let artistIdentifier: String?
    let albumIdentifier: String?
}

struct DownloadArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let provider: DownloadView.SearchProvider
    let artworkURL: URL?
}

struct DownloadArtistProfile {
    let tracks: [DownloadTrack]
    let albums: [DownloadAlbum]
}

private struct ArtistProfileScreen: View {
    private enum ArtistSection: String {
        case albums = "Albums"
        case tracks = "Tracks"
    }

    let artist: DownloadArtist
    @ObservedObject var vm: DownloadViewModel
    let onSelectAlbum: (DownloadAlbum) -> Void
    let onBrowseTrack: (DownloadTrack) -> Void

    @State private var profile = DownloadArtistProfile(tracks: [], albums: [])
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selectedSection: ArtistSection = .albums
    @State private var visibleAlbumCount = 8
    @State private var visibleTrackCount = 12

    private var hasResults: Bool {
        !profile.albums.isEmpty || !profile.tracks.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                artistHeroHeader

                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading artist profile...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    if hasResults {
                        artistSectionPicker
                            .padding(.horizontal, 20)
                    }

                    if selectedSection == .albums {
                        if !profile.albums.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Albums & Singles")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(min(visibleAlbumCount, profile.albums.count))/\(profile.albums.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 20)

                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 14),
                                        GridItem(.flexible(), spacing: 14)
                                    ],
                                    spacing: 14
                                ) {
                                    ForEach(Array(profile.albums.prefix(visibleAlbumCount))) { album in
                                        artistAlbumCard(album)
                                    }
                                }
                                .padding(.horizontal, 20)

                                if visibleAlbumCount < profile.albums.count {
                                    artistLoadMoreButton(title: "Load More Albums") {
                                        visibleAlbumCount = min(visibleAlbumCount + 8, profile.albums.count)
                                    }
                                    .padding(.horizontal, 20)
                                }
                            }
                        }
                    } else {
                        if !profile.tracks.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Tracks")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(min(visibleTrackCount, profile.tracks.count))/\(profile.tracks.count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 20)

                                VStack(spacing: 0) {
                                    ForEach(Array(profile.tracks.prefix(visibleTrackCount).enumerated()), id: \.element.id) { index, track in
                                        artistTrackRow(track)
                                        if index < min(visibleTrackCount, profile.tracks.count) - 1 {
                                            Divider().padding(.leading, 80)
                                        }
                                    }
                                }
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(.systemGray5), lineWidth: 1)
                                )
                                .padding(.horizontal, 20)

                                if visibleTrackCount < profile.tracks.count {
                                    artistLoadMoreButton(title: "Load More Tracks") {
                                        visibleTrackCount = min(visibleTrackCount + 12, profile.tracks.count)
                                    }
                                    .padding(.horizontal, 20)
                                }
                            }
                        }
                    }

                    if profile.albums.isEmpty && profile.tracks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "music.mic")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("No artist results found")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Artist")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id) {
            isLoading = true
            visibleAlbumCount = 8
            visibleTrackCount = 12
            selectedSection = .albums
            let loaded = await vm.loadArtistProfile(for: artist)
            profile = loaded
            errorText = (loaded.tracks.isEmpty && loaded.albums.isEmpty) ? "Could not load results for \(artist.name)." : nil
            if loaded.albums.isEmpty && !loaded.tracks.isEmpty {
                selectedSection = .tracks
            }
            isLoading = false
        }
    }

    private var artistHeroHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                AsyncImage(url: artist.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.35), Color(.secondarySystemFill)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.mic")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(artist.name)
                        .font(.system(size: 30, weight: .bold))
                    Text(artist.provider.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if hasResults {
                HStack(spacing: 10) {
                    artistCountPill(title: "Albums", value: profile.albums.count)
                    artistCountPill(title: "Tracks", value: profile.tracks.count)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func artistCountPill(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
    }

    private func artistLoadMoreButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(.systemGray5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var artistSectionPicker: some View {
        HStack(spacing: 8) {
            ForEach([ArtistSection.albums, .tracks], id: \.rawValue) { section in
                Button {
                    selectedSection = section
                } label: {
                    VStack(spacing: 6) {
                        Text(section.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedSection == section ? .primary : .secondary)

                        Rectangle()
                            .fill(selectedSection == section ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray5), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func artistAlbumCard(_ album: DownloadAlbum) -> some View {
        Button {
            onSelectAlbum(album)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                AsyncImage(url: album.artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            Color(.tertiarySystemFill)
                            Image(systemName: "rectangle.stack.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(album.artistLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack {
                    Spacer()
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(.systemGray5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func artistTrackRow(_ track: DownloadTrack) -> some View {
        HStack(spacing: 12) {
            Button {
                onBrowseTrack(track)
            } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: track.artworkURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            ZStack {
                                Color(.tertiarySystemFill)
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .lineLimit(1)
                            .font(.headline)
                        Text(track.artistLine)
                            .lineLimit(1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(track.albumName)
                            .lineLimit(1)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if vm.state(for: track.id) == .failed {
                    vm.retry(trackID: track.id)
                } else {
                    vm.enqueue(track: track)
                }
            } label: {
                switch vm.state(for: track.id) {
                case .downloading:
                    ProgressView().frame(width: 28, height: 28)
                case .queued:
                    Image(systemName: "clock.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red)
                case .idle:
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!vm.canEnqueue(trackID: track.id))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct DownloadQueueIndicator: View {
    let progress: Double
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 5)

            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel("Download queue progress \(label)")
    }
}

enum DownloadTrackState {
    case idle
    case queued
    case downloading
    case done
    case failed
}

struct DownloadDirectLinkAction: Identifiable {
    let id = UUID()
    let payload: DownloadDirectLinkPayload
}

enum DownloadDirectLinkPayload {
    case track(DownloadTrack)
    case collection(album: DownloadAlbum, tracks: [DownloadTrack], title: String, helperText: String)
    case artist(DownloadArtist)
}

struct BackendCandidate {
    let label: String
    let request: URLRequest?
    let tidalAPIBaseURL: String?
    let customDownload: ((_ trackID: String, _ suggestedName: String, _ fallbackExtension: String) async throws -> URL)?
}

struct BackendDownloadOutcome {
    let fileURL: URL
    let backendLabel: String
}

enum DownloaderServerPreference: String, CaseIterable, Identifiable {
    case auto
    case byeTunesAPI
    case yoinkify
    case qobuz
    case appleMusicAPI
    case deezerAPI
    case tidalAPI
    case pandoraAPI
    case amazonAPI
    case soundCloudAPI
    case youtubeAPI
    case hifiOne
    case hifiTwo

    static var allCases: [DownloaderServerPreference] {
        [.byeTunesAPI, .deezerAPI]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .byeTunesAPI: return "ByeTunes API"
        case .yoinkify: return "Yoinkify"
        case .qobuz: return "Qobuz"
        case .appleMusicAPI: return "Apple Music API"
        case .deezerAPI: return "Deezer"
        case .tidalAPI: return "Tidal API"
        case .pandoraAPI: return "Pandora API"
        case .amazonAPI: return "Amazon API"
        case .soundCloudAPI: return "SoundCloud API"
        case .youtubeAPI: return "YouTube API"
        case .hifiOne: return "HiFi One"
        case .hifiTwo: return "HiFi Two"
        }
    }

    var isDirectProviderOnly: Bool {
        switch self {
        case .byeTunesAPI, .appleMusicAPI, .deezerAPI, .tidalAPI, .pandoraAPI, .amazonAPI, .soundCloudAPI, .youtubeAPI:
            return true
        case .auto, .yoinkify, .qobuz, .hifiOne, .hifiTwo:
            return false
        }
    }
}

private enum DownloaderAutomaticQualityProfile: String {
    case low
    case medium
    case high
}

private enum QobuzQualityProfile: String {
    case lossless = "6"
    case hiRes = "7"
    case hiResMax = "27"
}

private enum TidalAPIRegistry {
    static let gistURL = "https://gist.githubusercontent.com/afkarxyz/2ce772b943321b9448b454f39403ce25/raw"
    static let cacheKey = "rotatingTidalAPIBaseURLs"
    static let lastUsedKey = "rotatingTidalAPILastUsedURL"
    static let defaultBaseURLs: [String] = []
}

private enum QobuzAPIRegistry {
    static let searchBaseURLs = [
        "https://api.zarz.moe/v1/qbz",
        "https://api.zarz.moe/v1/qbz2"
    ]

    static let downloadProviders: [(label: String, url: String)] = [
        ("Qobuz API (Zarz)", "https://api.zarz.moe/v1/dl/qbz")
    ]
}

private struct QobuzSearchOutcome {
    let trackIDs: [String]
    let bestScore: Int
}

enum DownloadPlatform: String {
    case appleMusic
    case spotify
    case deezer
    case qobuz
    case tidal
    case amazon
    case pandora
    case soundcloud
    case youtubeMusic
    case unknown

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .deezer: return "Deezer"
        case .qobuz: return "Qobuz"
        case .tidal: return "Tidal"
        case .amazon: return "Amazon Music"
        case .pandora: return "Pandora"
        case .soundcloud: return "SoundCloud"
        case .youtubeMusic: return "YouTube Music"
        case .unknown: return "Unknown"
        }
    }

    var backendGenreSource: String {
        switch self {
        case .appleMusic: return "itunes"
        case .spotify: return "spotify"
        case .deezer: return "itunes"
        case .qobuz: return "itunes"
        case .tidal: return "itunes"
        case .amazon: return "itunes"
        case .pandora: return "itunes"
        case .soundcloud: return "itunes"
        case .youtubeMusic: return "itunes"
        case .unknown: return "itunes"
        }
    }
}

struct DownloadSourceChoice {
    let platform: DownloadPlatform
    let url: String
    let backendGenreSource: String
}

private struct DownloadMetadataFallbackMatch {
    let title: String
    let artist: String
    let album: String?
    let source: DownloadSourceChoice?
    let providerName: String
}

private struct MetadataSearchBatch {
    let tracks: [DownloadTrack]
    let deezerCount: Int
}

private struct DeezerResolverCooldownPayload: Decodable {
    let retry_after: Int?
}

private struct CachedDeezerDescriptor: Codable {
    let downloadURL: String
    let requiresClientDecryption: Bool
    let fileFormat: String
    let trackID: String?
    let cachedAt: Date
}

private enum DeezerResolverPolicy {
    static let maxAutomaticWaitSeconds = 210
}

private enum DirectLinkKind {
    case appleSong(id: String, sourceURL: String)
    case appleAlbum(id: String, sourceURL: String)
    case appleArtist(id: String, sourceURL: String)
    case applePlaylist(id: String, sourceURL: String)
    case tidalTrack(id: String, sourceURL: String)
    case tidalAlbum(id: String, sourceURL: String)
    case tidalArtist(id: String, sourceURL: String)
    case tidalPlaylist(id: String, sourceURL: String)
    case spotifyTrack(id: String, sourceURL: String)
    case spotifyAlbum(id: String, sourceURL: String)
    case spotifyArtist(id: String, sourceURL: String)
    case spotifyPlaylist(id: String, sourceURL: String)
}

enum DownloadError: LocalizedError {
    case invalidURL(String)
    case searchFailed
    case mappingFailed(String)
    case remoteFailure(String)
    case httpError(Int, String)
    case emptyResponse
    case fileSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid download URL."
        case .searchFailed: return "Search failed."
        case .mappingFailed(let message): return message
        case .remoteFailure(let text): return "Backend failure: \(text)"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .emptyResponse: return "Backend returned empty response."
        case .fileSaveFailed(let message): return "Save failed: \(message)"
        }
    }
}

enum DownloadSupport {
    static func fileExtension(for mimeType: String?, fallback: String) -> String {
        guard let type = mimeType?.lowercased() else { return fallback }
        if type.contains("flac") { return "flac" }
        if type.contains("mpeg") || type.contains("mp3") { return "mp3" }
        if type.contains("aac") || type.contains("mp4") { return "m4a" }
        if type.contains("wav") { return "wav" }
        return fallback
    }

    static func tidyFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    static func tidalTrackID(from urlString: String) -> String? {
        guard let range = urlString.range(of: "/track/") else { return nil }
        let tail = urlString[range.upperBound...]
        let id = tail.split(separator: "?").first?.split(separator: "/").first
        let value = id.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static func qobuzTrackID(from urlString: String) -> String? {
        guard let range = urlString.range(of: "/track/") else { return nil }
        let tail = urlString[range.upperBound...]
        let id = tail
            .split(separator: "?").first?
            .split(separator: "/").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    nonisolated static func normalizedSearchValue(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let cleaned = folded.replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func artistTokens(from value: String) -> [String] {
        let separatorsPattern = #"\s*(?:,|&| x | y | feat\.?|ft\.?|with)\s*"#
        let canonicalized = value.replacingOccurrences(of: separatorsPattern, with: ",", options: .regularExpression)
        return canonicalized
            .components(separatedBy: ",")
            .map(normalizedSearchValue)
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var artistResults: [DownloadArtist] = []
    @Published var songResults: [DownloadTrack] = []
    @Published var albumResults: [DownloadAlbum] = []
    @Published var playlistResults: [DownloadAlbum] = []
    @Published var pendingDirectLinkAction: DownloadDirectLinkAction?
    @Published var isPaused = false
    private var queueTask: Task<Void, Never>?

    var shouldShowPauseButton: Bool {
        !pendingQueue.isEmpty || activeDownloadTrackID != nil
    }

    var shouldShowCancelButton: Bool {
        !pendingQueue.isEmpty || activeDownloadTrackID != nil || isPaused
    }
    @Published var isSearching = false
    @Published var errorText: String?
    @Published var canLoadMoreSongs = false
    @Published var canLoadMoreAlbums = false
    @Published var canLoadMorePlaylists = false
    @Published var isLoadingMoreSongs = false
    @Published var isLoadingMoreAlbums = false
    @Published var isLoadingMorePlaylists = false
    @Published var activeDownloadTrackID: String?
    @Published var activePreviewTrackID: String?
    @Published private(set) var previewLoadingTrackIDs: Set<String> = []
    @Published var emittedSongs: [SongMetadata] = []
    @Published private(set) var totalQueueCount = 0
    @Published private(set) var completedQueueCount = 0
    @Published private(set) var currentSongProgress: Double = 0
    @Published private(set) var currentDownloadSpeedBps: Double = 0

    private let session: URLSession = .shared
    private var pendingQueue: [DownloadTrack] = []
    private var isProcessingQueue = false
    private var trackStates: [String: DownloadTrackState] = [:]
    private var knownTracksByID: [String: DownloadTrack] = [:]
    private var queueOrder: [String] = []
    private var albumTrackIDs: [String: [String]] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @Published private var resolvingAlbumIDs: Set<String> = []
    private var lastSearchQuery = ""
    private var lastSearchProvider: DownloadView.SearchProvider = .appleMusic
    private let songPageSize = 25
    private let albumPageSize = 15
    private let playlistPageSize = 15
    private var tidalCachedSearchTracks: [DownloadTrack] = []
    private var tidalCachedSearchAlbums: [DownloadAlbum] = []
    private var tidalCachedSearchArtists: [DownloadArtist] = []
    private var tidalSearchItemsCache: [TidalSearchItem] = []
    private var tidalTotalItemCount = 0
    private var activeTidalSearchHost: String?
    private var metadataCachedSearchTracks: [DownloadTrack] = []
    private var metadataCachedSearchAlbums: [DownloadAlbum] = []
    private var metadataCachedSearchPlaylists: [DownloadAlbum] = []
    private var metadataAlbumTrackCache: [String: [DownloadTrack]] = [:]
    private var metadataDeezerOffset = 0
    private var metadataCanFetchMoreDeezer = false
    private var previewPlayer: AVPlayer?
    private var previewEndObserver: NSObjectProtocol?
    private var previewStatusObserver: NSKeyValueObservation?
    private var cachedPreviewURLs: [String: URL] = [:]

    init() {
        restorePersistedQueue()
    }

    var queueProgress: Double {
        guard totalQueueCount > 0 else { return 0 }
        return Double(completedQueueCount) / Double(totalQueueCount)
    }

    deinit {
        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
        }
    }

    var queueStatusText: String {
        if isPaused {
            return "Paused"
        }
        guard totalQueueCount > 0 else { return "Apple Music Search" }
        if let _ = activeDownloadTrackID, completedQueueCount < totalQueueCount {
            return "\(completedQueueCount + 1)/\(totalQueueCount)"
        }
        return "\(completedQueueCount)/\(totalQueueCount)"
    }

    var shouldShowQueueIndicator: Bool {
        isPaused || (totalQueueCount > 0 && (activeDownloadTrackID != nil || !pendingQueue.isEmpty || completedQueueCount < totalQueueCount))
    }

    var queueCounterText: String {
        if isPaused {
            return "Paused"
        }
        guard totalQueueCount > 0 else { return "0/0" }
        if activeDownloadTrackID != nil {
            return "\(min(completedQueueCount + 1, totalQueueCount))/\(totalQueueCount)"
        }
        return "\(min(completedQueueCount, totalQueueCount))/\(totalQueueCount)"
    }

    func state(for trackID: String) -> DownloadTrackState {
        trackStates[trackID] ?? .idle
    }

    func canEnqueue(trackID: String) -> Bool {
        switch state(for: trackID) {
        case .idle, .failed:
            return true
        case .queued, .downloading, .done:
            return false
        }
    }

    func state(forAlbumID albumID: String) -> DownloadTrackState {
        guard let trackIDs = albumTrackIDs[albumID], !trackIDs.isEmpty else { return .idle }
        let states = trackIDs.map { state(for: $0) }
        if states.contains(.downloading) { return .downloading }
        if states.contains(.queued) { return .queued }
        if !states.isEmpty && states.allSatisfy({ $0 == .done }) { return .done }
        if states.contains(.failed) { return .failed }
        return .idle
    }

    func isResolvingAlbum(albumID: String) -> Bool {
        resolvingAlbumIDs.contains(albumID)
    }

    func isPreviewPlaying(for trackID: String) -> Bool {
        activePreviewTrackID == trackID
    }

    func isPreviewLoading(for trackID: String) -> Bool {
        previewLoadingTrackIDs.contains(trackID)
    }

    func togglePreview(for track: DownloadTrack) {
        Task { @MainActor in
            if activePreviewTrackID == track.id {
                stopPreview()
                return
            }

            previewLoadingTrackIDs.insert(track.id)
            defer { previewLoadingTrackIDs.remove(track.id) }

            guard let url = await previewURL(for: track) else {
                errorText = "No preview available for \(track.name)."
                return
            }

            playPreview(for: track.id, url: url)
        }
    }

    private func playPreview(for trackID: String, url: URL) {
        stopPreview()

        guard configurePreviewAudioSession() else {
            errorText = "Could not start audio preview."
            return
        }

        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1.0
        previewPlayer = player
        activePreviewTrackID = trackID

        previewStatusObserver = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .failed {
                    self.errorText = "Could not play preview for this song."
                    self.log("Preview item failed: \(item.error?.localizedDescription ?? "unknown error")")
                    self.stopPreview()
                }
            }
        }

        previewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.stopPreview()
            }
        }

        player.play()
    }

    private func configurePreviewAudioSession() -> Bool {
        let audioSession = AVAudioSession.sharedInstance()

        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playback, .default, []),
            (.playback, .default, [.mixWithOthers]),
            (.ambient, .default, [])
        ]

        for (category, mode, options) in attempts {
            do {
                try audioSession.setCategory(category, mode: mode, options: options)
                try audioSession.setActive(true)
                return true
            } catch {
                log("Preview audio session setup failed for \(category.rawValue): \(error.localizedDescription)")
            }
        }

        return false
    }

    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        activePreviewTrackID = nil

        if let previewEndObserver {
            NotificationCenter.default.removeObserver(previewEndObserver)
            self.previewEndObserver = nil
        }

        previewStatusObserver = nil
    }

    private func previewURL(for track: DownloadTrack) async -> URL? {
        if let trackPreviewURL = track.previewURL {
            cachedPreviewURLs[track.id] = trackPreviewURL
            return trackPreviewURL
        }

        if let cached = cachedPreviewURLs[track.id] {
            return cached
        }

        let resolved: URL?
        switch track.provider {
        case .appleMusic, .spotify, .metadata, .tidal:
            resolved = await resolveITunesPreviewURL(for: track)
        }

        if let resolved {
            cachedPreviewURLs[track.id] = resolved
        }

        return resolved
    }

    private func resolveITunesPreviewURL(for track: DownloadTrack) async -> URL? {
        let query = [track.artistLine, track.name]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        let results = await SongMetadata.searchiTunes(query: query, limit: 10)
        let match = results.first { song in
            guard
                let title = song.trackName,
                let artist = song.artistName
            else {
                return false
            }

            let normalizedTrackTitle = DownloadSupport.normalizedSearchValue(track.name)
            let normalizedSongTitle = DownloadSupport.normalizedSearchValue(title)
            guard normalizedTrackTitle == normalizedSongTitle else {
                return false
            }

            return matchesArtistLine(track.artistLine, artistName: artist)
        } ?? results.first

        return match?.previewUrl.flatMap(URL.init(string:))
    }

    func pauseQueue() {
        guard !isPaused else { return }
        isPaused = true
        queueTask?.cancel()
        log("Download queue paused by user.")
    }

    func resumeQueue() {
        guard isPaused else { return }
        isPaused = false
        log("Download queue resumed by user.")
        queueTask = Task { await processQueueIfNeeded() }
    }

    func cancelQueue() {
        queueTask?.cancel()
        for track in pendingQueue {
            trackStates[track.id] = .idle
        }
        pendingQueue.removeAll()
        if let activeID = activeDownloadTrackID {
            trackStates[activeID] = .idle
        }
        activeDownloadTrackID = nil
        totalQueueCount = 0
        completedQueueCount = 0
        currentSongProgress = 0
        currentDownloadSpeedBps = 0
        isPaused = false
        log("Download queue cancelled and cleared by user.")
        syncQueuePersistence()
    }

    func enqueue(track: DownloadTrack) {
        _ = enqueueMany([track])
    }

    @discardableResult
    func enqueue(tracks: [DownloadTrack], albumID: String? = nil) -> Int {
        if let albumID {
            albumTrackIDs[albumID] = tracks.map(\.id)
        }
        let added = enqueueMany(tracks)
        return added
    }

    func loadTracks(for album: DownloadAlbum) async -> [DownloadTrack] {
        guard !resolvingAlbumIDs.contains(album.id) else { return [] }
        resolvingAlbumIDs.insert(album.id)
        defer { resolvingAlbumIDs.remove(album.id) }
        switch album.provider {
        case .appleMusic:
            let albumID = album.albumIdentifier ?? album.id
            return await fetchAlbumTracks(albumID: albumID, fallbackAlbumName: album.name, sourceURL: album.sourceURL)
        case .spotify:
            if album.sourceURL.contains("spotify.com") {
                if let (_, tracks) = await fetchSpotifyAlbum(id: album.id, sourceURL: album.sourceURL) {
                    return tracks
                }
                return []
            } else {
                let albumID = album.albumIdentifier ?? album.id
                let amTracks = await fetchAlbumTracks(albumID: albumID, fallbackAlbumName: album.name, sourceURL: album.sourceURL)
                return amTracks.map { track in
                    DownloadTrack(
                        id: track.id,
                        name: track.name,
                        artistLine: track.artistLine,
                        albumName: track.albumName,
                        artworkURL: track.artworkURL,
                        isExplicit: track.isExplicit,
                        sourceURL: track.sourceURL,
                        sourceContext: track.sourceContext,
                        provider: .spotify,
                        artistIdentifier: track.artistIdentifier,
                        albumIdentifier: track.albumIdentifier,
                        previewURL: track.previewURL
                    )
                }
            }
        case .tidal:
            return await fetchTidalAlbumTracks(for: album)
        case .metadata:
            if let tracks = metadataAlbumTrackCache[album.id], !tracks.isEmpty {
                return tracks
            }
            let query = "\(album.artistLine) \(album.name)"
            let batch = await fetchMetadataSearchTracks(query: query, limit: 50, deezerIndex: 0, includeITunes: true)
            let matchingTracks = batch.tracks.filter { track in
                DownloadSupport.normalizedSearchValue(track.albumName) == DownloadSupport.normalizedSearchValue(album.name) &&
                matchesArtistLine(track.artistLine, artistName: album.artistLine)
            }
            return matchingTracks.isEmpty ? batch.tracks : matchingTracks
        }
    }

    func loadTracks(forPlaylist playlist: DownloadAlbum) async -> [DownloadTrack] {
        switch playlist.provider {
        case .appleMusic:
            let playlistID = playlist.albumIdentifier ?? playlist.id
            guard let playlistResult = await fetchAppleMusicPlaylist(id: playlistID, sourceURL: playlist.sourceURL) else { return [] }
            return playlistResult.relationships?.tracks?.data.map {
                DownloadTrack(
                    id: $0.id,
                    name: $0.attributes.name,
                    artistLine: $0.attributes.artistName,
                    albumName: $0.attributes.albumName ?? playlist.name,
                    artworkURL: $0.attributes.artwork?.artworkURL(width: 400, height: 400) ?? playlist.artworkURL,
                    isExplicit: $0.attributes.contentRating == "explicit",
                    sourceURL: $0.attributes.url ?? playlist.sourceURL,
                    sourceContext: .song,
                    provider: .appleMusic,
                    artistIdentifier: nil,
                    albumIdentifier: nil,
                    previewURL: nil
                )
            } ?? []
        case .spotify:
            if playlist.sourceURL.contains("spotify.com") {
                if let (_, tracks) = await fetchSpotifyPlaylist(id: playlist.id, sourceURL: playlist.sourceURL) {
                    return tracks
                }
                return []
            } else {
                let playlistID = playlist.albumIdentifier ?? playlist.id
                guard let playlistResult = await fetchAppleMusicPlaylist(id: playlistID, sourceURL: playlist.sourceURL) else { return [] }
                let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
                return playlistResult.relationships?.tracks?.data.map {
                    DownloadTrack(
                        id: $0.id,
                        name: $0.attributes.name,
                        artistLine: $0.attributes.artistName,
                        albumName: $0.attributes.albumName ?? playlist.name,
                        artworkURL: $0.attributes.artwork?.artworkURL(width: 400, height: 400) ?? playlist.artworkURL,
                        isExplicit: $0.attributes.contentRating == "explicit",
                        sourceURL: $0.attributes.url ?? playlist.sourceURL,
                        sourceContext: .song,
                        provider: .spotify,
                        artistIdentifier: nil,
                        albumIdentifier: nil,
                        previewURL: nil
                    )
                } ?? []
            }
        case .tidal, .metadata:
            return []
        }
    }

    func enqueue(album: DownloadAlbum) async {
        let tracks = await loadTracks(for: album)
        guard !tracks.isEmpty else {
            errorText = "Could not load tracks for album \(album.name)"
            return
        }

        let added = enqueue(tracks: tracks, albumID: album.id)
        if added == 0 {
            errorText = "All tracks from \(album.name) are already queued or downloaded."
        } else {
            log("Queued \(added) tracks from album \(album.name)")
        }
    }

    func retry(trackID: String) {
        guard let track = knownTracksByID[trackID] else { return }
        errorText = nil
        _ = enqueueMany([track])
    }

    func removeFailed(trackID: String) {
        guard trackStates[trackID] == .failed else { return }
        trackStates.removeValue(forKey: trackID)
        queueOrder.removeAll { $0 == trackID }
        if totalQueueCount > completedQueueCount {
            totalQueueCount = max(0, totalQueueCount - 1)
        }
        syncQueuePersistence()
    }

    func removeQueued(trackID: String) {
        guard trackStates[trackID] == .queued else { return }
        pendingQueue.removeAll { $0.id == trackID }
        trackStates.removeValue(forKey: trackID)
        queueOrder.removeAll { $0 == trackID }
        totalQueueCount = max(0, totalQueueCount - 1)
        completedQueueCount = min(completedQueueCount, totalQueueCount)
        syncQueuePersistence()
    }

    func retry(album: DownloadAlbum) async {
        errorText = nil

        if let knownTrackIDs = albumTrackIDs[album.id], !knownTrackIDs.isEmpty {
            let knownTracks = knownTrackIDs.compactMap { knownTracksByID[$0] }
            if !knownTracks.isEmpty {
                let added = enqueue(tracks: knownTracks, albumID: album.id)
                if added == 0 {
                    errorText = "No failed tracks from \(album.name) are available to retry."
                }
                return
            }
        }

        await enqueue(album: album)
    }

    func retry(playlist: DownloadAlbum) async {
        errorText = nil

        if let knownTrackIDs = albumTrackIDs[playlist.id], !knownTrackIDs.isEmpty {
            let knownTracks = knownTrackIDs.compactMap { knownTracksByID[$0] }
            if !knownTracks.isEmpty {
                let added = enqueue(tracks: knownTracks, albumID: playlist.id)
                if added == 0 {
                    errorText = "No failed tracks from \(playlist.name) are available to retry."
                }
                return
            }
        }

        let tracks = await loadTracks(forPlaylist: playlist)
        guard !tracks.isEmpty else {
            errorText = "Could not load tracks for playlist \(playlist.name)"
            return
        }

        let added = enqueue(tracks: tracks, albumID: playlist.id)
        if added == 0 {
            errorText = "All tracks from \(playlist.name) are already queued or downloaded."
        }
    }

    private func searchSpotify(query: String, limit: Int, offset: Int) async -> (songs: [DownloadTrack], albums: [DownloadAlbum], playlists: [DownloadAlbum])? {
        guard let token = await fetchSpotifyToken() else { return nil }
        
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track,album,playlist"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            
            var parsedTracks: [DownloadTrack] = []
            var parsedAlbums: [DownloadAlbum] = []
            var parsedPlaylists: [DownloadAlbum] = []
            
            if let tracksObj = json["tracks"] as? [String: Any],
               let items = tracksObj["items"] as? [[String: Any]] {
                for item in items {
                    if let trackID = item["id"] as? String {
                        let name = item["name"] as? String ?? "Unknown Title"
                        let artists = item["artists"] as? [[String: Any]] ?? []
                        let artistLine = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                        let explicit = item["explicit"] as? Bool ?? false
                        let trackURL = "https://open.spotify.com/track/\(trackID)"
                        
                        let album = item["album"] as? [String: Any]
                        let albumName = album?["name"] as? String ?? "Unknown Album"
                        let artworkURLString = (album?["images"] as? [[String: Any]])?.first?["url"] as? String
                        let artworkURL = artworkURLString.flatMap(URL.init(string:))
                        
                        parsedTracks.append(DownloadTrack(
                            id: trackID,
                            name: name,
                            artistLine: artistLine.isEmpty ? "Unknown Artist" : artistLine,
                            albumName: albumName,
                            artworkURL: artworkURL,
                            isExplicit: explicit,
                            sourceURL: trackURL,
                            sourceContext: .song,
                            provider: .spotify,
                            artistIdentifier: nil,
                            albumIdentifier: album?["id"] as? String,
                            previewURL: (item["preview_url"] as? String).flatMap(URL.init(string:))
                        ))
                    }
                }
            }
            
            if let albumsObj = json["albums"] as? [String: Any],
               let items = albumsObj["items"] as? [[String: Any]] {
                for item in items {
                    if let albumID = item["id"] as? String {
                        let name = item["name"] as? String ?? "Unknown Album"
                        let artists = item["artists"] as? [[String: Any]] ?? []
                        let artistLine = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                        let artworkURLString = (item["images"] as? [[String: Any]])?.first?["url"] as? String
                        let artworkURL = artworkURLString.flatMap(URL.init(string:))
                        let albumURL = "https://open.spotify.com/album/\(albumID)"
                        
                        parsedAlbums.append(DownloadAlbum(
                            id: albumID,
                            name: name,
                            artistLine: artistLine.isEmpty ? "Unknown Artist" : artistLine,
                            artworkURL: artworkURL,
                            sourceURL: albumURL,
                            provider: .spotify,
                            artistIdentifier: nil,
                            albumIdentifier: albumID
                        ))
                    }
                }
            }
            
            if let playlistsObj = json["playlists"] as? [String: Any],
               let items = playlistsObj["items"] as? [[String: Any]] {
                for item in items {
                    if let playlistID = item["id"] as? String {
                        let name = item["name"] as? String ?? "Unknown Playlist"
                        let owner = (item["owner"] as? [String: Any])?["display_name"] as? String ?? "Spotify Playlist"
                        let artworkURLString = (item["images"] as? [[String: Any]])?.first?["url"] as? String
                        let artworkURL = artworkURLString.flatMap(URL.init(string:))
                        let playlistURL = "https://open.spotify.com/playlist/\(playlistID)"
                        
                        parsedPlaylists.append(DownloadAlbum(
                            id: playlistID,
                            name: name,
                            artistLine: owner,
                            artworkURL: artworkURL,
                            sourceURL: playlistURL,
                            provider: .spotify,
                            artistIdentifier: nil,
                            albumIdentifier: playlistID
                        ))
                    }
                }
            }
            
            return (parsedTracks, parsedAlbums, parsedPlaylists)
        } catch {
            log("Spotify search failed: \(error.localizedDescription)")
            return nil
        }
    }

    func search(query: String, provider: DownloadView.SearchProvider) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            artistResults = []
            songResults = []
            albumResults = []
            playlistResults = []
            canLoadMoreSongs = false
            canLoadMoreAlbums = false
            canLoadMorePlaylists = false
            return
        }
        lastSearchQuery = trimmed
        lastSearchProvider = provider
        tidalCachedSearchTracks = []
        metadataCachedSearchTracks = []
        metadataCachedSearchAlbums = []
        metadataCachedSearchPlaylists = []
        metadataAlbumTrackCache = [:]
        metadataDeezerOffset = 0
        metadataCanFetchMoreDeezer = false
        isSearching = true
        errorText = nil
        defer { isSearching = false }

        if let directLink = parseDirectLink(from: trimmed) {
            let handled = await handleDirectLinkSearch(directLink)
            canLoadMoreSongs = false
            canLoadMoreAlbums = false
            canLoadMorePlaylists = false
            if handled {
                return
            }
        }

        if isUnsupportedPastedTidalLink(trimmed) {
            errorText = "Tidal pasted links are not supported. Paste an Apple Music link instead."
            canLoadMoreSongs = false
            canLoadMoreAlbums = false
            canLoadMorePlaylists = false
            return
        }

        switch provider {
        case .appleMusic:
            artistResults = []
            activeTidalSearchHost = nil
            tidalCachedSearchArtists = []
            tidalCachedSearchTracks = []
            tidalCachedSearchAlbums = []
            tidalSearchItemsCache = []
            tidalTotalItemCount = 0
            let songs = await AppleMusicAPI.shared.searchSongs(query: trimmed, limit: songPageSize, offset: 0)
            let albums = await searchAlbums(query: trimmed, limit: albumPageSize, offset: 0)
            let playlists = await searchPlaylists(query: trimmed, limit: playlistPageSize, offset: 0)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"

            songResults = songs.map { item in
                let songURL = item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
                return DownloadTrack(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    albumName: item.attributes.albumName ?? "Unknown Album",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    isExplicit: item.attributes.contentRating == "explicit",
                    sourceURL: songURL,
                    sourceContext: .song,
                    provider: .appleMusic,
                    artistIdentifier: item.relationships?.artists?.data.first?.id,
                    albumIdentifier: item.relationships?.albums?.data.first?.id,
                    previewURL: nil
                )
            }

            albumResults = albums.map { item in
                let albumURL = "https://music.apple.com/\(region)/album/\(item.id)"
                return DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: albumURL,
                    provider: .appleMusic,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            playlistResults = playlists.map { item in
                let playlistURL = "https://music.apple.com/\(region)/playlist/\(item.id)"
                return DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.curatorName ?? "Apple Music Playlist",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: playlistURL,
                    provider: .appleMusic,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            canLoadMoreSongs = songs.count == songPageSize
            canLoadMoreAlbums = albums.count == albumPageSize
            canLoadMorePlaylists = playlists.count == playlistPageSize

        case .spotify:
            artistResults = []
            activeTidalSearchHost = nil
            tidalCachedSearchArtists = []
            tidalCachedSearchTracks = []
            tidalCachedSearchAlbums = []
            tidalSearchItemsCache = []
            tidalTotalItemCount = 0

            let songs = await AppleMusicAPI.shared.searchSongs(query: trimmed, limit: songPageSize, offset: 0)
            let albums = await searchAlbums(query: trimmed, limit: albumPageSize, offset: 0)
            let playlists = await searchPlaylists(query: trimmed, limit: playlistPageSize, offset: 0)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"

            songResults = songs.map { item in
                let songURL = item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
                return DownloadTrack(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    albumName: item.attributes.albumName ?? "Unknown Album",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    isExplicit: item.attributes.contentRating == "explicit",
                    sourceURL: songURL,
                    sourceContext: .song,
                    provider: .spotify,
                    artistIdentifier: item.relationships?.artists?.data.first?.id,
                    albumIdentifier: item.relationships?.albums?.data.first?.id,
                    previewURL: nil
                )
            }

            albumResults = albums.map { item in
                let albumURL = "https://music.apple.com/\(region)/album/\(item.id)"
                return DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: albumURL,
                    provider: .spotify,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            playlistResults = playlists.map { item in
                let playlistURL = "https://music.apple.com/\(region)/playlist/\(item.id)"
                return DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.curatorName ?? "Apple Music Playlist",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: playlistURL,
                    provider: .spotify,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            canLoadMoreSongs = songs.count == songPageSize
            canLoadMoreAlbums = albums.count == albumPageSize
            canLoadMorePlaylists = playlists.count == playlistPageSize

        case .tidal:
            activeTidalSearchHost = nil
            let response = await fetchPreferredTidalSearchResponse(query: trimmed, limit: songPageSize, offset: 0, logLabel: "search display")
            let items = response?.data.items ?? []
            tidalSearchItemsCache = items
            tidalTotalItemCount = response?.data.totalNumberOfItems ?? items.count
            tidalCachedSearchTracks = mapTidalSearchItemsToTracks(items)
            tidalCachedSearchAlbums = Array(uniqueAlbums(mapTidalSearchItemsToAlbums(items)).prefix(200))

            artistResults = []
            songResults = Array(tidalCachedSearchTracks.prefix(songPageSize))
            albumResults = Array(tidalCachedSearchAlbums.prefix(albumPageSize))
            playlistResults = []
            canLoadMoreSongs = songResults.count < tidalTotalItemCount
            canLoadMoreAlbums = albumResults.count < tidalCachedSearchAlbums.count || tidalSearchItemsCache.count < tidalTotalItemCount
            canLoadMorePlaylists = false

        case .metadata:
            activeTidalSearchHost = nil
            artistResults = []
            tidalCachedSearchArtists = []
            tidalCachedSearchTracks = []
            tidalCachedSearchAlbums = []
            tidalSearchItemsCache = []
            tidalTotalItemCount = 0

            let batch = await fetchMetadataSearchTracks(
                query: trimmed,
                limit: songPageSize,
                deezerIndex: 0,
                includeITunes: true
            )
            metadataCachedSearchTracks = uniqueTracks(batch.tracks)
            metadataDeezerOffset = batch.deezerCount
            metadataCanFetchMoreDeezer = batch.deezerCount == songPageSize
            metadataCachedSearchAlbums = buildMetadataAlbums(from: metadataCachedSearchTracks)
            metadataCachedSearchPlaylists = []

            songResults = Array(metadataCachedSearchTracks.prefix(songPageSize))
            albumResults = Array(metadataCachedSearchAlbums.prefix(albumPageSize))
            playlistResults = []
            canLoadMoreSongs = songResults.count < metadataCachedSearchTracks.count || metadataCanFetchMoreDeezer
            canLoadMoreAlbums = albumResults.count < metadataCachedSearchAlbums.count || metadataCanFetchMoreDeezer
            canLoadMorePlaylists = false
        }
    }

    func loadMoreSongs() async {
        guard !isLoadingMoreSongs, canLoadMoreSongs, !lastSearchQuery.isEmpty else { return }
        isLoadingMoreSongs = true
        defer { isLoadingMoreSongs = false }

        switch lastSearchProvider {
        case .appleMusic:
            let offset = songResults.count
            let songs = await AppleMusicAPI.shared.searchSongs(query: lastSearchQuery, limit: songPageSize, offset: offset)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let mappedSongs = songs.map { item in
                let songURL = item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
                return DownloadTrack(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    albumName: item.attributes.albumName ?? "Unknown Album",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    isExplicit: item.attributes.contentRating == "explicit",
                    sourceURL: songURL,
                    sourceContext: .song,
                    provider: .appleMusic,
                    artistIdentifier: item.relationships?.artists?.data.first?.id,
                    albumIdentifier: item.relationships?.albums?.data.first?.id,
                    previewURL: nil
                )
            }
            songResults.append(contentsOf: mappedSongs.filter { incoming in
                !songResults.contains(where: { $0.id == incoming.id })
            })
            canLoadMoreSongs = songs.count == songPageSize
        case .spotify:
            let offset = songResults.count
            let songs = await AppleMusicAPI.shared.searchSongs(query: lastSearchQuery, limit: songPageSize, offset: offset)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let mappedSongs = songs.map { item in
                let songURL = item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
                return DownloadTrack(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    albumName: item.attributes.albumName ?? "Unknown Album",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    isExplicit: item.attributes.contentRating == "explicit",
                    sourceURL: songURL,
                    sourceContext: .song,
                    provider: .spotify,
                    artistIdentifier: item.relationships?.artists?.data.first?.id,
                    albumIdentifier: item.relationships?.albums?.data.first?.id,
                    previewURL: nil
                )
            }
            songResults.append(contentsOf: mappedSongs.filter { incoming in
                !songResults.contains(where: { $0.id == incoming.id })
            })
            canLoadMoreSongs = songs.count == songPageSize
        case .tidal:
            await expandTidalSearchCacheIfNeeded(minimumItemCount: songResults.count + songPageSize)
            tidalCachedSearchTracks = mapTidalSearchItemsToTracks(tidalSearchItemsCache)
            tidalCachedSearchAlbums = Array(uniqueAlbums(mapTidalSearchItemsToAlbums(tidalSearchItemsCache)).prefix(400))
            let nextCount = min(songResults.count + songPageSize, tidalCachedSearchTracks.count)
            songResults = Array(tidalCachedSearchTracks.prefix(nextCount))
            albumResults = Array(tidalCachedSearchAlbums.prefix(max(albumResults.count, min(albumPageSize, tidalCachedSearchAlbums.count))))
            canLoadMoreSongs = songResults.count < tidalTotalItemCount
            canLoadMoreAlbums = albumResults.count < tidalCachedSearchAlbums.count || tidalSearchItemsCache.count < tidalTotalItemCount
            canLoadMorePlaylists = false
        case .metadata:
            await expandMetadataSearchCacheIfNeeded(minimumTrackCount: songResults.count + songPageSize)
            let nextCount = min(songResults.count + songPageSize, metadataCachedSearchTracks.count)
            songResults = Array(metadataCachedSearchTracks.prefix(nextCount))
            albumResults = Array(metadataCachedSearchAlbums.prefix(max(albumResults.count, min(albumPageSize, metadataCachedSearchAlbums.count))))
            canLoadMoreSongs = songResults.count < metadataCachedSearchTracks.count || metadataCanFetchMoreDeezer
            canLoadMoreAlbums = albumResults.count < metadataCachedSearchAlbums.count || metadataCanFetchMoreDeezer
            canLoadMorePlaylists = false
        }
    }

    func loadMoreAlbums() async {
        guard !isLoadingMoreAlbums, canLoadMoreAlbums, !lastSearchQuery.isEmpty else { return }
        isLoadingMoreAlbums = true
        defer { isLoadingMoreAlbums = false }

        switch lastSearchProvider {
        case .appleMusic:
            let offset = albumResults.count
            let albums = await searchAlbums(query: lastSearchQuery, limit: albumPageSize, offset: offset)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let mappedAlbums = albums.map { item in
                let albumURL = "https://music.apple.com/\(region)/album/\(item.id)"
                return DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: albumURL,
                    provider: .appleMusic,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            albumResults.append(contentsOf: mappedAlbums.filter { incoming in
                !albumResults.contains(where: { $0.id == incoming.id })
            })
            canLoadMoreAlbums = albums.count == albumPageSize
        case .spotify:
            let offset = albumResults.count
            let albums = await searchAlbums(query: lastSearchQuery, limit: albumPageSize, offset: offset)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let mappedAlbums = albums.map { item in
                let albumURL = "https://music.apple.com/\(region)/album/\(item.id)"
                return DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: albumURL,
                    provider: .spotify,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            albumResults.append(contentsOf: mappedAlbums.filter { incoming in
                !albumResults.contains(where: { $0.id == incoming.id })
            })
            canLoadMoreAlbums = albums.count == albumPageSize
        case .tidal:
            let desiredAlbumCount = albumResults.count + albumPageSize
            while tidalCachedSearchAlbums.count < desiredAlbumCount && tidalSearchItemsCache.count < tidalTotalItemCount {
                await expandTidalSearchCacheIfNeeded(minimumAlbumCount: desiredAlbumCount)
                tidalCachedSearchTracks = mapTidalSearchItemsToTracks(tidalSearchItemsCache)
                tidalCachedSearchAlbums = Array(uniqueAlbums(mapTidalSearchItemsToAlbums(tidalSearchItemsCache)).prefix(400))
                if tidalSearchItemsCache.count >= tidalTotalItemCount {
                    break
                }
            }
            albumResults = Array(tidalCachedSearchAlbums.prefix(min(desiredAlbumCount, tidalCachedSearchAlbums.count)))
            canLoadMoreSongs = songResults.count < tidalTotalItemCount
            canLoadMoreAlbums = albumResults.count < tidalCachedSearchAlbums.count || tidalSearchItemsCache.count < tidalTotalItemCount
            canLoadMorePlaylists = false
        case .metadata:
            let desiredAlbumCount = albumResults.count + albumPageSize
            await expandMetadataSearchCacheIfNeeded(minimumAlbumCount: desiredAlbumCount)
            albumResults = Array(metadataCachedSearchAlbums.prefix(min(desiredAlbumCount, metadataCachedSearchAlbums.count)))
            canLoadMoreSongs = songResults.count < metadataCachedSearchTracks.count || metadataCanFetchMoreDeezer
            canLoadMoreAlbums = albumResults.count < metadataCachedSearchAlbums.count || metadataCanFetchMoreDeezer
            canLoadMorePlaylists = false
        }
    }

    func loadMorePlaylists() async {
        guard !isLoadingMorePlaylists, canLoadMorePlaylists, !lastSearchQuery.isEmpty else { return }
        isLoadingMorePlaylists = true
        defer { isLoadingMorePlaylists = false }

        switch lastSearchProvider {
        case .appleMusic:
            let offset = playlistResults.count
            let playlists = await searchPlaylists(query: lastSearchQuery, limit: playlistPageSize, offset: offset)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let mappedPlaylists = playlists.map { item in
                DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.curatorName ?? "Apple Music Playlist",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: "https://music.apple.com/\(region)/playlist/\(item.id)",
                    provider: .appleMusic,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            playlistResults.append(contentsOf: mappedPlaylists.filter { incoming in
                !playlistResults.contains(where: { $0.id == incoming.id })
            })
            canLoadMorePlaylists = playlists.count == playlistPageSize
        case .spotify:
            let offset = playlistResults.count
            let playlists = await searchPlaylists(query: lastSearchQuery, limit: playlistPageSize, offset: offset)
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let mappedPlaylists = playlists.map { item in
                DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.curatorName ?? "Apple Music Playlist",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: "https://music.apple.com/\(region)/playlist/\(item.id)",
                    provider: .spotify,
                    artistIdentifier: nil,
                    albumIdentifier: item.id
                )
            }
            playlistResults.append(contentsOf: mappedPlaylists.filter { incoming in
                !playlistResults.contains(where: { $0.id == incoming.id })
            })
            canLoadMorePlaylists = playlists.count == playlistPageSize
        case .tidal, .metadata:
            canLoadMorePlaylists = false
        }
    }

    func loadArtistProfile(for artist: DownloadArtist) async -> DownloadArtistProfile {
        switch artist.provider {
        case .appleMusic:
            let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
            let filteredSongs = await fetchAppleMusicArtistSongs(artistName: artist.name)
            let tracks = filteredSongs.map { item in
                let songURL = item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
                return DownloadTrack(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    albumName: item.attributes.albumName ?? "Unknown Album",
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    isExplicit: item.attributes.contentRating == "explicit",
                    sourceURL: songURL,
                    sourceContext: .song,
                    provider: .appleMusic,
                    artistIdentifier: item.relationships?.artists?.data.first?.id,
                    albumIdentifier: item.relationships?.albums?.data.first?.id,
                    previewURL: nil
                )
            }

            let filteredAlbums = await fetchAppleMusicArtistAlbums(artistName: artist.name)
            let mappedAlbums = filteredAlbums.map { item in
                DownloadAlbum(
                    id: item.id,
                    name: item.attributes.name,
                    artistLine: item.attributes.artistName,
                    artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                    sourceURL: "https://music.apple.com/\(region)/album/\(item.id)",
                    provider: .appleMusic,
                    artistIdentifier: artist.id,
                    albumIdentifier: item.id
                )
            }

            return DownloadArtistProfile(tracks: tracks, albums: uniqueAlbums(mappedAlbums))

        case .tidal, .metadata, .spotify:
            return await buildMetadataArtistProfile(for: artist.name)
        }
    }

    private func buildMetadataArtistProfile(for artistName: String) async -> DownloadArtistProfile {
        let batch = await fetchMetadataSearchTracks(
            query: artistName,
            limit: 100,
            deezerIndex: 0,
            includeITunes: true
        )
        let tracks = uniqueTracksForMetadataProfile(batch.tracks).filter {
            matchesArtistLine($0.artistLine, artistName: artistName)
        }
        let albums = uniqueAlbumsForMetadataProfile(buildMetadataAlbums(from: tracks))
        return DownloadArtistProfile(
            tracks: Array(tracks.prefix(100)),
            albums: Array(albums.prefix(100))
        )
    }

    private func handleDirectLinkSearch(_ link: DirectLinkKind) async -> Bool {
        artistResults = []
        songResults = []
        albumResults = []
        playlistResults = []
        pendingDirectLinkAction = nil

        switch link {
        case .appleSong(let id, let sourceURL):
            guard let song = await AppleMusicAPI.shared.fetchSong(id: id, urlHint: sourceURL) else {
                errorText = "Could not load that Apple Music song link."
                return true
            }
            let track = makeAppleMusicTrack(from: song, sourceURLOverride: sourceURL)
            pendingDirectLinkAction = DownloadDirectLinkAction(payload: .track(track))
            return true

        case .appleAlbum(let id, let sourceURL):
            guard let album = await fetchAppleMusicAlbum(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Apple Music album link."
                return true
            }
            let albumResult = makeAppleMusicAlbum(from: album, sourceURLOverride: sourceURL)
            let tracks = await fetchAlbumTracks(albumID: id, fallbackAlbumName: album.attributes?.name ?? "Unknown Album", sourceURL: sourceURL)
            albumTrackIDs[albumResult.id] = tracks.map(\.id)
            pendingDirectLinkAction = DownloadDirectLinkAction(
                payload: .collection(
                    album: albumResult,
                    tracks: tracks,
                    title: "Album Download",
                    helperText: "Choose the tracks you want to download, or grab the full album in one tap."
                )
            )
            return true

        case .appleArtist(let id, let sourceURL):
            guard let artistData = await fetchAppleMusicArtist(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Apple Music artist link."
                return true
            }
            let artist = DownloadArtist(
                id: artistData.id,
                name: artistData.attributes.name,
                provider: .appleMusic,
                artworkURL: artistData.attributes.artwork?.artworkURL(width: 400, height: 400)
            )
            pendingDirectLinkAction = DownloadDirectLinkAction(payload: .artist(artist))
            return true

        case .applePlaylist(let id, let sourceURL):
            guard let playlist = await fetchAppleMusicPlaylist(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Apple Music playlist link."
                return true
            }
            let tracks = playlist.relationships?.tracks?.data.map {
                makeAppleMusicTrack(from: $0)
            } ?? []
            let playlistContainer = DownloadAlbum(
                id: playlist.id,
                name: playlist.attributes.name,
                artistLine: playlist.attributes.curatorName ?? "Apple Music Playlist",
                artworkURL: playlist.attributes.artwork?.artworkURL(width: 400, height: 400) ?? tracks.first?.artworkURL,
                sourceURL: sourceURL,
                provider: .appleMusic,
                artistIdentifier: nil,
                albumIdentifier: playlist.id
            )
            pendingDirectLinkAction = DownloadDirectLinkAction(
                payload: .collection(
                    album: playlistContainer,
                    tracks: tracks,
                    title: "Playlist Download",
                    helperText: "Choose the songs you want to download, or grab the full playlist in one tap."
                )
            )
            return true

        case .tidalTrack(let id, let sourceURL):
            if let mappedAppleLink = await resolveMappedDirectLink(from: sourceURL, platform: .appleMusic) {
                return await handleDirectLinkSearch(mappedAppleLink)
            }
            if let fallbackTrack = await fetchTidalTrackFromPublicPage(sourceURL: sourceURL, fallbackID: id) {
                pendingDirectLinkAction = DownloadDirectLinkAction(payload: .track(fallbackTrack))
                return true
            }
            errorText = "Could not resolve that Tidal track link."
            return true

        case .tidalAlbum(let id, let sourceURL):
            if let mappedAppleLink = await resolveMappedDirectLink(from: sourceURL, platform: .appleMusic) {
                return await handleDirectLinkSearch(mappedAppleLink)
            }
            let fallbackAlbum = DownloadAlbum(
                id: id,
                name: "Tidal Album",
                artistLine: "Unknown Artist",
                artworkURL: nil,
                sourceURL: sourceURL,
                provider: .tidal,
                artistIdentifier: nil,
                albumIdentifier: id
            )
            let tracks = await fetchTidalAlbumTracks(for: fallbackAlbum)
            guard !tracks.isEmpty else {
                errorText = "Could not load that Tidal album link."
                return true
            }
            let album = DownloadAlbum(
                id: id,
                name: tracks.first?.albumName ?? "Tidal Album",
                artistLine: tracks.first?.artistLine ?? "Unknown Artist",
                artworkURL: tracks.first?.artworkURL,
                sourceURL: sourceURL,
                provider: .tidal,
                artistIdentifier: tracks.first?.artistIdentifier,
                albumIdentifier: id
            )
            albumTrackIDs[album.id] = tracks.map(\.id)
            pendingDirectLinkAction = DownloadDirectLinkAction(
                payload: .collection(
                    album: album,
                    tracks: tracks,
                    title: "Album Download",
                    helperText: "Choose the tracks you want to download, or grab the full album in one tap."
                )
            )
            return true

        case .tidalArtist(let id, let sourceURL):
            if let mappedAppleLink = await resolveMappedDirectLink(from: sourceURL, platform: .appleMusic) {
                return await handleDirectLinkSearch(mappedAppleLink)
            }
            guard let artist = await fetchTidalArtist(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Tidal artist link."
                return true
            }
            pendingDirectLinkAction = DownloadDirectLinkAction(payload: .artist(artist))
            return true

        case .tidalPlaylist(_, let sourceURL):
            if let mappedAppleLink = await resolveMappedDirectLink(from: sourceURL, platform: .appleMusic) {
                return await handleDirectLinkSearch(mappedAppleLink)
            }
            errorText = "Tidal playlist links are not supported by the current backends."
            return true

        case .spotifyTrack(let id, let sourceURL):
            guard let track = await fetchSpotifyTrack(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Spotify track link."
                return true
            }
            pendingDirectLinkAction = DownloadDirectLinkAction(payload: .track(track))
            return true

        case .spotifyAlbum(let id, let sourceURL):
            guard let (albumResult, tracks) = await fetchSpotifyAlbum(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Spotify album link."
                return true
            }
            albumTrackIDs[albumResult.id] = tracks.map(\.id)
            pendingDirectLinkAction = DownloadDirectLinkAction(
                payload: .collection(
                    album: albumResult,
                    tracks: tracks,
                    title: "Album Download",
                    helperText: "Choose the tracks you want to download, or grab the full album in one tap."
                )
            )
            return true

        case .spotifyArtist(let id, let sourceURL):
            guard let artist = await fetchSpotifyArtist(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Spotify artist link."
                return true
            }
            pendingDirectLinkAction = DownloadDirectLinkAction(payload: .artist(artist))
            return true

        case .spotifyPlaylist(let id, let sourceURL):
            guard let (playlistContainer, tracks) = await fetchSpotifyPlaylist(id: id, sourceURL: sourceURL) else {
                errorText = "Could not load that Spotify playlist link."
                return true
            }
            albumTrackIDs[playlistContainer.id] = tracks.map(\.id)
            pendingDirectLinkAction = DownloadDirectLinkAction(
                payload: .collection(
                    album: playlistContainer,
                    tracks: tracks,
                    title: "Playlist Download",
                    helperText: "Choose the songs you want to download, or grab the full playlist in one tap."
                )
            )
            return true
        }
    }

    private func parseDirectLink(from value: String) -> DirectLinkKind? {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased() else {
            return nil
        }

        let sourceURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        if host.contains("music.apple.com") {
            if let songID = components.queryItems?.first(where: { $0.name == "i" })?.value, !songID.isEmpty {
                return .appleSong(id: songID, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "song"),
               let id = pathParts.dropFirst(index + 1).last,
               !id.isEmpty {
                return .appleSong(id: id, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "album"),
               let id = pathParts.dropFirst(index + 1).last,
               !id.isEmpty {
                return .appleAlbum(id: id, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "artist"),
               let id = pathParts.dropFirst(index + 1).last,
               !id.isEmpty {
                return .appleArtist(id: id, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "playlist"),
               let id = pathParts.dropFirst(index + 1).last,
               !id.isEmpty {
                return .applePlaylist(id: id, sourceURL: sourceURL)
            }
        } else if host.contains("spotify.com") {
            if let index = pathParts.firstIndex(of: "track"),
               let id = pathParts.dropFirst(index + 1).first,
               !id.isEmpty {
                return .spotifyTrack(id: id, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "album"),
               let id = pathParts.dropFirst(index + 1).first,
               !id.isEmpty {
                return .spotifyAlbum(id: id, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "artist"),
               let id = pathParts.dropFirst(index + 1).first,
               !id.isEmpty {
                return .spotifyArtist(id: id, sourceURL: sourceURL)
            }

            if let index = pathParts.firstIndex(of: "playlist"),
               let id = pathParts.dropFirst(index + 1).first,
               !id.isEmpty {
                return .spotifyPlaylist(id: id, sourceURL: sourceURL)
            }
        }

        return nil
    }

    private func isUnsupportedPastedTidalLink(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased() else {
            return false
        }
        return host.contains("tidal.com")
    }

    private func resolveMappedDirectLink(from sourceURL: String, platform: DownloadPlatform) async -> DirectLinkKind? {
        guard let mappedURL = try? await fetchMappedURL(for: sourceURL, platform: platform) else {
            return nil
        }
        return parseDirectLink(from: mappedURL)
    }

    private func makeAppleMusicTrack(
        from item: AppleMusicAPI.AppleMusicSong,
        sourceURLOverride: String? = nil,
        provider: DownloadView.SearchProvider = .appleMusic,
        trackIDOverride: String? = nil
    ) -> DownloadTrack {
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        let songURL = sourceURLOverride ?? item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
        return DownloadTrack(
            id: trackIDOverride ?? item.id,
            name: item.attributes.name,
            artistLine: item.attributes.artistName,
            albumName: item.attributes.albumName ?? "Unknown Album",
            artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
            isExplicit: item.attributes.contentRating == "explicit",
            sourceURL: songURL,
            sourceContext: .song,
            provider: provider,
            artistIdentifier: item.relationships?.artists?.data.first?.id,
            albumIdentifier: item.relationships?.albums?.data.first?.id,
            previewURL: nil
        )
    }

    private func makeAppleMusicAlbum(
        from item: AppleMusicAPI.AppleMusicSong,
        provider: DownloadView.SearchProvider = .appleMusic,
        sourceURLOverride: String? = nil
    ) -> DownloadAlbum? {
        guard let albumID = item.relationships?.albums?.data.first?.id else {
            return nil
        }
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        return DownloadAlbum(
            id: albumID,
            name: item.attributes.albumName ?? "Unknown Album",
            artistLine: item.attributes.artistName,
            artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
            sourceURL: sourceURLOverride ?? "https://music.apple.com/\(region)/album/\(albumID)",
            provider: provider,
            artistIdentifier: item.relationships?.artists?.data.first?.id,
            albumIdentifier: albumID
        )
    }

    private func makeAppleMusicAlbum(
        from item: AppleMusicAlbumDetailsData,
        sourceURLOverride: String? = nil
    ) -> DownloadAlbum {
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        let albumID = item.id ?? item.attributes?.playParams?.id ?? "unknown-album"
        return DownloadAlbum(
            id: albumID,
            name: item.attributes?.name ?? "Unknown Album",
            artistLine: item.attributes?.artistName ?? "Unknown Artist",
            artworkURL: item.attributes?.artwork?.artworkURL(width: 400, height: 400),
            sourceURL: sourceURLOverride ?? "https://music.apple.com/\(region)/album/\(albumID)",
            provider: .appleMusic,
            artistIdentifier: nil,
            albumIdentifier: albumID
        )
    }

    private func buildAlbumsFromTracks(
        _ tracks: [DownloadTrack],
        provider: DownloadView.SearchProvider,
        playlistSourceURL: String? = nil
    ) -> [DownloadAlbum] {
        var orderedAlbums: [DownloadAlbum] = []
        var seen = Set<String>()
        for track in tracks {
            let album = DownloadAlbum(
                id: track.albumIdentifier ?? "\(provider.rawValue)-album-\(DownloadSupport.normalizedSearchValue(track.artistLine))-\(DownloadSupport.normalizedSearchValue(track.albumName))",
                name: track.albumName,
                artistLine: track.artistLine,
                artworkURL: track.artworkURL,
                sourceURL: playlistSourceURL ?? track.sourceURL,
                provider: provider,
                artistIdentifier: track.artistIdentifier,
                albumIdentifier: track.albumIdentifier
            )
            guard seen.insert(album.id).inserted else { continue }
            orderedAlbums.append(album)
        }
        return orderedAlbums
    }

    private func fetchAppleMusicArtistSongs(artistName: String) async -> [AppleMusicAPI.AppleMusicSong] {
        let pageSize = 50
        let maxPages = 5
        var offset = 0
        var collected: [AppleMusicAPI.AppleMusicSong] = []
        var seenIDs = Set<String>()

        for _ in 0..<maxPages {
            let page = await AppleMusicAPI.shared.searchSongs(query: artistName, limit: pageSize, offset: offset)
            if page.isEmpty { break }

            let filteredPage = page.filter {
                matchesArtistLine($0.attributes.artistName, artistName: artistName)
            }

            for song in filteredPage where !seenIDs.contains(song.id) {
                seenIDs.insert(song.id)
                collected.append(song)
            }

            if page.count < pageSize { break }
            offset += pageSize
        }

        return collected
    }

    private func fetchAppleMusicArtistAlbums(artistName: String) async -> [AppleMusicAlbumResult] {
        let pageSize = 50
        let maxPages = 5
        var offset = 0
        var collected: [AppleMusicAlbumResult] = []
        var seenIDs = Set<String>()

        for _ in 0..<maxPages {
            let page = await searchAlbums(query: artistName, limit: pageSize, offset: offset)
            if page.isEmpty { break }

            let filteredPage = page.filter {
                matchesArtistLine($0.attributes.artistName, artistName: artistName)
            }

            for album in filteredPage where !seenIDs.contains(album.id) {
                seenIDs.insert(album.id)
                collected.append(album)
            }

            if page.count < pageSize { break }
            offset += pageSize
        }

        return collected
    }

    private func fetchAppleMusicAlbum(id: String, sourceURL: String? = nil) async -> AppleMusicAlbumDetailsData? {
        guard let fallbackAlbum = await AppleMusicAPI.shared.fetchAlbumPublic(id: id, urlHint: sourceURL) else {
            return nil
        }

        let fallbackTracks = await AppleMusicAPI.shared.fetchAlbumTracksPublic(id: id, urlHint: sourceURL)
        return AppleMusicAlbumDetailsData(
            id: fallbackAlbum.id,
            attributes: AppleMusicDirectAlbumAttributes(
                name: fallbackAlbum.name,
                artistName: fallbackAlbum.artistName,
                artwork: fallbackAlbum.artwork,
                playParams: AppleMusicPlayParams(id: fallbackAlbum.id)
            ),
            relationships: AppleMusicAlbumRelationships(
                tracks: AppleMusicAlbumTracksPage(data: fallbackTracks.map {
                    AppleMusicAlbumTrack(
                        id: $0.id,
                        attributes: AppleMusicAlbumTrackAttributes(
                            name: $0.attributes.name,
                            artistName: $0.attributes.artistName,
                            albumName: $0.attributes.albumName,
                            url: $0.attributes.url,
                            contentRating: $0.attributes.contentRating,
                            artwork: $0.attributes.artwork
                        )
                    )
                })
            )
        )
    }

    private func fetchAppleMusicArtist(id: String, sourceURL: String? = nil) async -> AppleMusicArtistResult? {
        guard let fallbackArtist = await AppleMusicAPI.shared.fetchArtistPublic(id: id, urlHint: sourceURL) else {
            return nil
        }

        return AppleMusicArtistResult(
            id: fallbackArtist.id,
            attributes: AppleMusicArtistAttributes(
                name: fallbackArtist.name,
                artwork: fallbackArtist.artwork
            )
        )
    }

    private func fetchAppleMusicPlaylist(id: String, sourceURL: String? = nil) async -> AppleMusicPlaylistResult? {
        guard let fallbackPlaylist = await AppleMusicAPI.shared.fetchPlaylistPublic(id: id, urlHint: sourceURL) else {
            return nil
        }

        let fallbackTracks = await AppleMusicAPI.shared.fetchPlaylistTracksPublic(id: id, urlHint: sourceURL)
        return AppleMusicPlaylistResult(
            id: fallbackPlaylist.id,
            attributes: AppleMusicPlaylistAttributes(
                name: fallbackPlaylist.name,
                curatorName: fallbackPlaylist.curatorName,
                artwork: fallbackPlaylist.artwork
            ),
            relationships: AppleMusicPlaylistRelationships(
                tracks: AppleMusicPlaylistTracksPage(data: fallbackTracks)
            )
        )
    }

    private func fetchMetadataSearchTracks(
        query: String,
        limit: Int,
        deezerIndex: Int,
        includeITunes: Bool
    ) async -> MetadataSearchBatch {
        async let deezerResults = SongMetadata.searchDeezer(query: query, limit: limit, index: deezerIndex)
        async let iTunesResults = includeITunes ? SongMetadata.searchiTunes(query: query, limit: min(limit, 50)) : []

        let deezerSongs = await deezerResults
        let iTunesSongs = await iTunesResults
        let tracks = iTunesSongs.compactMap(metadataTrack(from:)) + deezerSongs.map(metadataTrack(from:))
        return MetadataSearchBatch(tracks: tracks, deezerCount: deezerSongs.count)
    }

    private func expandMetadataSearchCacheIfNeeded(minimumTrackCount: Int? = nil, minimumAlbumCount: Int? = nil) async {
        while metadataCanFetchMoreDeezer {
            let hasEnoughTracks = minimumTrackCount.map { metadataCachedSearchTracks.count >= $0 } ?? false
            let hasEnoughAlbums = minimumAlbumCount.map { metadataCachedSearchAlbums.count >= $0 } ?? false

            if minimumTrackCount != nil, hasEnoughTracks {
                break
            }
            if minimumAlbumCount != nil, hasEnoughAlbums {
                break
            }

            let batch = await fetchMetadataSearchTracks(
                query: lastSearchQuery,
                limit: songPageSize,
                deezerIndex: metadataDeezerOffset,
                includeITunes: false
            )
            metadataDeezerOffset += batch.deezerCount
            metadataCanFetchMoreDeezer = batch.deezerCount == songPageSize

            let existingIDs = Set(metadataCachedSearchTracks.map(\.id))
            let freshTracks = batch.tracks.filter { !existingIDs.contains($0.id) }
            if freshTracks.isEmpty {
                break
            }

            metadataCachedSearchTracks = uniqueTracks(metadataCachedSearchTracks + freshTracks)
            metadataCachedSearchAlbums = buildMetadataAlbums(from: metadataCachedSearchTracks)
        }
    }

    private func expandTidalSearchCacheIfNeeded(minimumItemCount: Int? = nil, minimumAlbumCount: Int? = nil) async {
        while true {
            let hasEnoughItems = minimumItemCount.map { tidalSearchItemsCache.count >= $0 } ?? false
            let currentAlbumCount = uniqueAlbums(mapTidalSearchItemsToAlbums(tidalSearchItemsCache)).count
            let hasEnoughAlbums = minimumAlbumCount.map { currentAlbumCount >= $0 } ?? false

            if minimumItemCount != nil, hasEnoughItems {
                break
            }
            if minimumAlbumCount != nil, hasEnoughAlbums {
                break
            }
            if tidalSearchItemsCache.count >= tidalTotalItemCount {
                break
            }

            let response = await fetchPreferredTidalSearchResponse(
                query: lastSearchQuery,
                limit: songPageSize,
                offset: tidalSearchItemsCache.count,
                logLabel: "search display"
            )
            guard let response else { break }

            let freshItems = response.data.items.filter { incoming in
                !tidalSearchItemsCache.contains(where: { $0.id == incoming.id })
            }
            if freshItems.isEmpty {
                break
            }

            tidalSearchItemsCache.append(contentsOf: freshItems)
            tidalTotalItemCount = max(tidalTotalItemCount, response.data.totalNumberOfItems)
        }
    }

    private func processQueueIfNeeded() async {
        guard !isPaused else { return }
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        beginBackgroundTaskIfNeeded()
        defer {
            isProcessingQueue = false
            endBackgroundTaskIfNeeded()
        }

        while !pendingQueue.isEmpty {
            if Task.isCancelled || isPaused {
                break
            }
            let track = pendingQueue.removeFirst()
            errorText = nil
            activeDownloadTrackID = track.id
            trackStates[track.id] = .downloading
            currentSongProgress = 0
            currentDownloadSpeedBps = 0
            syncQueuePersistence()

            do {
                let outcome = try await downloadWithFallbacks(track: track)
                log("Download finished via \(outcome.backendLabel): \(outcome.fileURL.lastPathComponent)")
                var song = try await SongMetadata.fromURL(outcome.fileURL)
                try await validateDownloadedSong(song, sourceTrack: track, backendLabel: outcome.backendLabel)
                song = await enrichDownloadedSong(song, sourceTrack: track)
                song = persistDownloadedSongIfNeeded(song)
                emittedSongs.append(song)
                trackStates[track.id] = .done
            } catch {
                if Task.isCancelled {
                    log("Download cancelled/paused by user.")
                    trackStates[track.id] = .idle
                    if isPaused {
                        pendingQueue.insert(track, at: 0)
                    }
                    break
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("Download failed: \(message)")
                errorText = message
                trackStates[track.id] = .failed
            }

            completedQueueCount += 1
            activeDownloadTrackID = nil
            currentSongProgress = 0
            currentDownloadSpeedBps = 0
            syncQueuePersistence()
        }
    }

    @discardableResult
    private func enqueueMany(_ tracks: [DownloadTrack]) -> Int {
        let validTracks = tracks.filter { canEnqueue(trackID: $0.id) }
        guard !validTracks.isEmpty else { return 0 }

        if totalQueueCount == completedQueueCount && activeDownloadTrackID == nil && pendingQueue.isEmpty {
            totalQueueCount = 0
            completedQueueCount = 0
        }

        for track in validTracks {
            knownTracksByID[track.id] = track
            if !queueOrder.contains(track.id) {
                queueOrder.append(track.id)
            }
            pendingQueue.append(track)
            trackStates[track.id] = .queued
            totalQueueCount += 1
        }

        syncQueuePersistence()
        if !isPaused {
            queueTask = Task { await processQueueIfNeeded() }
        }
        return validTracks.count
    }

    private func enrichDownloadedSong(_ initialSong: SongMetadata, sourceTrack: DownloadTrack) async -> SongMetadata {
        var song = initialSong

        song = await SongMetadata.enrichWithExactAppleMusicTrack(song, trackID: sourceTrack.id, urlHint: sourceTrack.sourceURL)

        if song.storeId == 0 {
            song = await SongMetadata.enrichWithAppleMusicMetadata(song)
        }

        let appleSubscriptionLyrics = UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")
        if !appleSubscriptionLyrics && (song.lyrics == nil || song.lyrics?.isEmpty == true) {
            if let fetchedLyrics = await SongMetadata.fetchLyrics(
                title: song.title,
                artist: song.artist,
                album: song.album,
                durationMs: song.durationMs
            ) {
                song.lyrics = fetchedLyrics
            }
        }

        return song
    }

    private func validateDownloadedSong(
        _ song: SongMetadata,
        sourceTrack: DownloadTrack,
        backendLabel: String
    ) async throws {
        let isAMDL = backendLabel.localizedCaseInsensitiveContains("am-dl")
        let isQobuz = backendLabel.localizedCaseInsensitiveContains("qobuz")
        guard isAMDL || isQobuz else { return }

        if song.fileSize < 32_768 {
            log("\(backendLabel) validation failed for \(sourceTrack.id): file too small (\(song.fileSize) bytes)")
            throw DownloadError.remoteFailure("\(backendLabel) did not return a full audio file.")
        }

        if !downloadedFileLooksLikeAudio(song.localURL) {
            log("\(backendLabel) validation failed for \(sourceTrack.id): file signature does not match audio type at \(song.localURL.lastPathComponent)")
            throw DownloadError.remoteFailure("\(backendLabel) returned an invalid audio file.")
        }

        if !downloadedFileCanBeDecoded(song.localURL) {
            log("\(backendLabel) validation failed for \(sourceTrack.id): audio is not decodable at \(song.localURL.lastPathComponent) (\(song.fileSize) bytes)")
            throw DownloadError.remoteFailure("\(backendLabel) returned unreadable audio data.")
        }

        guard isAMDL else { return }

        if song.durationMs <= 0 {
            log("AM-DL validation failed for \(sourceTrack.id): unreadable duration (\(song.durationMs) ms)")
            throw DownloadError.remoteFailure("AM-DL returned an unreadable audio file.")
        }

        if let expectedSong = await AppleMusicAPI.shared.fetchSong(id: sourceTrack.id, urlHint: sourceTrack.sourceURL),
           let expectedDurationMs = expectedSong.attributes.durationInMillis,
           expectedDurationMs > 0 {
            let deltaMs = abs(song.durationMs - expectedDurationMs)
            let allowedDeltaMs = max(12_000, expectedDurationMs / 8)
            if deltaMs > allowedDeltaMs {
                log("AM-DL validation failed for \(sourceTrack.id): duration mismatch actual=\(song.durationMs) expected=\(expectedDurationMs) delta=\(deltaMs)")
                throw DownloadError.remoteFailure("AM-DL returned media that does not match the expected song duration.")
            }
        }
    }

    private func downloadedFileLooksLikeAudio(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let header = (try? handle.read(upToCount: 32)) ?? Data()
        guard !header.isEmpty else { return false }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "flac":
            return header.count >= 4 && String(data: header.prefix(4), encoding: .ascii) == "fLaC"
        case "mp3":
            if header.count >= 3 && String(data: header.prefix(3), encoding: .ascii) == "ID3" {
                return true
            }
            guard header.count >= 2 else { return false }
            return header[0] == 0xFF && (header[1] & 0xE0) == 0xE0
        case "m4a", "mp4", "aac", "alac":
            guard header.count >= 12 else { return false }
            return String(data: header[4..<8], encoding: .ascii) == "ftyp"
        case "wav", "wave":
            guard header.count >= 12 else { return false }
            return String(data: header.prefix(4), encoding: .ascii) == "RIFF" &&
                String(data: header[8..<12], encoding: .ascii) == "WAVE"
        default:
            if header.count >= 4 && String(data: header.prefix(4), encoding: .ascii) == "fLaC" {
                return true
            }
            if header.count >= 3 && String(data: header.prefix(3), encoding: .ascii) == "ID3" {
                return true
            }
            if header.count >= 12 &&
                String(data: header[4..<8], encoding: .ascii) == "ftyp" {
                return true
            }
            if header.count >= 12 &&
                String(data: header.prefix(4), encoding: .ascii) == "RIFF" &&
                String(data: header[8..<12], encoding: .ascii) == "WAVE" {
                return true
            }
            if header.count >= 2 && header[0] == 0xFF && (header[1] & 0xE0) == 0xE0 {
                return true
            }
            return false
        }
    }

    private func downloadedFileCanBeDecoded(_ url: URL) -> Bool {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            return audioFile.length > 0 && audioFile.processingFormat.sampleRate > 0
        } catch {
            log("Download decode probe failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "DownloadQueue") { [weak self] in
            Logger.shared.log("[Download] Background task expired while queue was active")
            self?.endBackgroundTaskIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func downloadWithFallbacks(track: DownloadTrack) async throws -> BackendDownloadOutcome {
        let serverPreference: DownloaderServerPreference = .auto
        let resolvedSource = await resolvedPrimaryDownloadSource(for: track, serverPreference: serverPreference)
        log("Using source URL (\(resolvedSource.platform.displayName)): \(resolvedSource.url)")

        let candidates = try await primaryCandidates(for: resolvedSource, serverPreference: serverPreference, track: track)
        if !candidates.isEmpty {
            if let outcome = try await executeCandidatesUntilSuccess(
                candidates,
                trackID: track.id,
                suggestedName: "\(track.artistLine) - \(track.name)",
                fallbackExtension: "flac"
            ) {
                return outcome
            }
        }

        // Last resort: If the current source is not Spotify, try mapping to Spotify and using the ByeTunes API with it.
        if resolvedSource.platform != .spotify {
            log("Attempting last-resort Spotify mapping for \(track.name)...")
            do {
                let seed = mappingSeedURL(for: track.sourceURL)
                let spotifyURL = try await fetchMappedURL(for: seed, platform: .spotify)
                log("Mapped to Spotify for last-resort retry: \(spotifyURL)")
                
                let spotifySource = DownloadSourceChoice(
                    platform: .spotify,
                    url: spotifyURL,
                    backendGenreSource: DownloadPlatform.spotify.backendGenreSource
                )
                let spotifyCandidates = try await primaryCandidates(for: spotifySource, serverPreference: serverPreference, track: track)
                if !spotifyCandidates.isEmpty {
                    if let outcome = try await executeCandidatesUntilSuccess(
                        spotifyCandidates,
                        trackID: track.id,
                        suggestedName: "\(track.artistLine) - \(track.name)",
                        fallbackExtension: "flac"
                    ) {
                        return outcome
                    }
                }
            } catch {
                log("Last-resort Spotify mapping failed: \(error.localizedDescription)")
            }
        }

        throw DownloadError.mappingFailed("All configured download backends failed.")
    }

    private func preferredDownloadSource(for sourceURL: String) -> DownloadSourceChoice {
        let platform: DownloadPlatform
        if sourceURL.contains("music.apple.com") || sourceURL.contains("itunes.apple.com") {
            platform = .appleMusic
        } else if sourceURL.contains("spotify.com") {
            platform = .spotify
        } else if sourceURL.contains("deezer.com") {
            platform = .deezer
        } else if sourceURL.contains("qobuz.com") {
            platform = .qobuz
        } else if sourceURL.contains("tidal.com") {
            platform = .tidal
        } else if sourceURL.contains("music.amazon.") || sourceURL.contains("amazon.com/music") || sourceURL.contains("amazon.com/gp/product/") {
            platform = .amazon
        } else if sourceURL.contains("pandora.com") {
            platform = .pandora
        } else if sourceURL.contains("soundcloud.com") {
            platform = .soundcloud
        } else if sourceURL.contains("music.youtube.com") || sourceURL.contains("youtube.com") || sourceURL.contains("youtu.be") {
            platform = .youtubeMusic
        } else {
            platform = .unknown
        }
        return DownloadSourceChoice(platform: platform, url: sourceURL, backendGenreSource: platform.backendGenreSource)
    }

    private func resolvedPrimaryDownloadSource(
        for track: DownloadTrack,
        serverPreference: DownloaderServerPreference
    ) async -> DownloadSourceChoice {
        var source = preferredDownloadSource(for: track.sourceURL)
        if track.provider == .spotify && source.platform == .appleMusic {
            do {
                let seed = mappingSeedURL(for: track.sourceURL)
                let mappedURL = try await fetchMappedURL(for: seed, platform: .spotify)
                log("Mapped Apple Music source URL \(track.sourceURL) to Spotify: \(mappedURL)")
                source = DownloadSourceChoice(
                    platform: .spotify,
                    url: mappedURL,
                    backendGenreSource: DownloadPlatform.spotify.backendGenreSource
                )
            } catch {
                log("Failed to map Apple Music track \(track.name) to Spotify: \(error.localizedDescription)")
            }
        }
        guard serverPreference == .deezerAPI,
              let deezerSource = await resolvedDeezerFallbackSource(for: track, source: source) else {
            return source
        }
        return deezerSource
    }

    private func resolvedDeezerFallbackSource(
        for track: DownloadTrack,
        source: DownloadSourceChoice
    ) async -> DownloadSourceChoice? {
        if let cached = cachedDeezerSourceURL(for: track.id) {
            return DownloadSourceChoice(
                platform: .deezer,
                url: cached,
                backendGenreSource: DownloadPlatform.deezer.backendGenreSource
            )
        }

        if source.platform == .deezer {
            cacheDeezerSourceURL(source.url, for: track.id)
            return source
        }

        if let exactDeezerSource = await resolveExactDeezerSource(for: track, source: source) {
            log("Mapped track to Deezer via exact metadata: \(exactDeezerSource.url)")
            cacheDeezerSourceURL(exactDeezerSource.url, for: track.id)
            return exactDeezerSource
        }

        do {
            let mappedURL = try await fetchMappedURL(for: mappingSeedURL(for: track.sourceURL), platform: .deezer)
            log("Mapped track to Deezer via Song.link: \(mappedURL)")
            cacheDeezerSourceURL(mappedURL, for: track.id)
            return DownloadSourceChoice(
                platform: .deezer,
                url: mappedURL,
                backendGenreSource: DownloadPlatform.deezer.backendGenreSource
            )
        } catch {
            log("Song.link Deezer mapping failed for \(track.name): \(error.localizedDescription)")
        }

        if let metadataFallback = await bestMetadataFallback(for: track),
           let deezerSource = metadataFallback.source,
           deezerSource.platform == .deezer {
            log("Mapped track to Deezer via metadata fallback: \(deezerSource.url)")
            cacheDeezerSourceURL(deezerSource.url, for: track.id)
            return deezerSource
        }

        if let searchedDeezerSource = await resolveDeezerSource(for: track) {
            log("Mapped track to Deezer via direct Deezer search: \(searchedDeezerSource.url)")
            cacheDeezerSourceURL(searchedDeezerSource.url, for: track.id)
            return searchedDeezerSource
        }

        return nil
    }

    private func primaryCandidates(
        for source: DownloadSourceChoice,
        serverPreference: DownloaderServerPreference,
        track: DownloadTrack? = nil
    ) async throws -> [BackendCandidate] {
        var candidates: [BackendCandidate] = []
        if (serverPreference == .auto || serverPreference == .byeTunesAPI) &&
            (source.platform == .appleMusic || source.platform == .spotify || source.platform == .deezer || source.platform == .unknown) {
            candidates.append(contentsOf: try await byeTunesCandidates(for: source, serverPreference: serverPreference, track: track))
        }

        if serverPreference == .yoinkify &&
            (source.platform == .appleMusic || source.platform == .spotify || source.platform == .deezer || source.platform == .unknown) {
            let pow = await yoinkProofOfWork()
            let format = yoinkifyFormat(for: serverPreference)

            if let url = URL(string: "https://yoinkify.com/api/download") {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var payload: [String: Any] = [
                    "url": source.url,
                    "format": format,
                    "genreSource": source.backendGenreSource
                ]
                if let pow {
                    payload["pow"] = pow
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                candidates.append(BackendCandidate(label: "Yoinkify", request: request, tidalAPIBaseURL: nil, customDownload: nil))
            }
        }

        if serverPreference == .auto,
           let track,
           let deezerSource = await resolvedDeezerFallbackSource(for: track, source: source) {
            candidates.append(contentsOf: try deezerExtensionCandidates(for: deezerSource))
        }

        switch source.platform {
        case .appleMusic:
            if serverPreference == .appleMusicAPI {
                candidates.append(contentsOf: try appleExtensionCandidates(for: source))
            }
        case .deezer:
            if serverPreference == .deezerAPI {
                candidates.append(contentsOf: try deezerExtensionCandidates(for: source))
            }
        case .tidal:
            if serverPreference == .tidalAPI {
                candidates.append(contentsOf: try tidalExtensionCandidates(for: source))
            }
        case .amazon:
            if serverPreference == .amazonAPI {
                candidates.append(contentsOf: amazonExtensionCandidates(for: source))
            }
        case .pandora:
            if serverPreference == .pandoraAPI {
                candidates.append(contentsOf: try pandoraExtensionCandidates(for: source))
            }
        case .soundcloud:
            if serverPreference == .soundCloudAPI {
                candidates.append(contentsOf: try cobaltExtensionCandidates(for: source, providerLabel: "SoundCloud API (Cobalt)"))
            }
        case .youtubeMusic:
            if serverPreference == .youtubeAPI {
                candidates.append(contentsOf: try cobaltExtensionCandidates(for: source, providerLabel: "YouTube API (Cobalt)"))
            }
        case .spotify, .qobuz, .unknown:
            break
        }

        return candidates
    }

    private func byeTunesCandidates(
        for source: DownloadSourceChoice,
        serverPreference: DownloaderServerPreference,
        track: DownloadTrack? = nil
    ) async throws -> [BackendCandidate] {
        let urlString = "\(Config.byeTunesApiUrl)/api/download"
        guard let url = URL(string: urlString) else {
            throw DownloadError.invalidURL(urlString)
        }

        let desiredFormat = yoinkifyFormat(for: serverPreference)
        let wantsSyncedLyrics =
            UserDefaults.standard.bool(forKey: "fetchLyrics") ||
            UserDefaults.standard.bool(forKey: "appleSubscriptionLyrics")

        func makeCandidate(label: String, format: String, overrideURL: String? = nil) throws -> BackendCandidate {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "url": overrideURL ?? source.url,
                "format": format,
                "genreSource": source.backendGenreSource,
                "syncedLyrics": wantsSyncedLyrics
            ])
            return BackendCandidate(label: label, request: request, tidalAPIBaseURL: nil, customDownload: nil)
        }

        var candidates = [try makeCandidate(label: "ByeTunes API", format: desiredFormat)]
        if desiredFormat.lowercased() != "mp3" {
            candidates.append(try makeCandidate(label: "ByeTunes API (MP3 Fallback)", format: "mp3"))
        }

        // For Apple Music sources, add a Spotify-URL candidate as fallback.
        // The ByeTunes server resolves Spotify → Deezer far more reliably than
        // Apple Music → Deezer. We try three paths to get a real
        // open.spotify.com/track/ID URL (ISRC search format is rejected by server).
        if source.platform == .appleMusic, let track {
            var spotifyURL: String?

            // Path 1: song.link with cached Deezer URL → Spotify
            // Most reliable — track IS on Deezer so song.link can map it.
            if spotifyURL == nil, let cachedDeezer = cachedDeezerSourceURL(for: track.id) {
                if let mapped = try? await fetchMappedURL(for: cachedDeezer, platform: .spotify) {
                    spotifyURL = mapped
                    log("ByeTunes Spotify fallback: song.link Deezer→Spotify: \(mapped)")
                }
            }

            // Path 2: Spotify anonymous web player token + ISRC search
            // Spotify publicly vends unauthenticated tokens for the web player
            // which allow metadata queries including ISRC search.
            if spotifyURL == nil {
                var isrc: String?

                // Get ISRC from cached Deezer track
                if let cachedDeezer = cachedDeezerSourceURL(for: track.id),
                   let deezerID = cachedDeezer.components(separatedBy: "/").last, !deezerID.isEmpty,
                   let apiURL = URL(string: "https://api.deezer.com/track/\(deezerID)"),
                   let (data, _) = try? await URLSession.shared.data(from: apiURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let deezerISRC = json["isrc"] as? String, !deezerISRC.isEmpty {
                    isrc = deezerISRC
                }

                // Get ISRC from Deezer title search if not cached
                if isrc == nil {
                    let results = await SongMetadata.searchDeezer(
                        query: "\(track.artistLine) \(track.name)", limit: 3, index: 0
                    )
                    isrc = results.first?.isrc?.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if let isrc, !isrc.isEmpty {
                    log("ByeTunes Spotify fallback: ISRC \(isrc) — fetching anon Spotify token")
                    if let tokenURL = URL(string: "https://open.spotify.com/get_access_token?reason=transport&productType=web_player"),
                       let (tokenData, _) = try? await URLSession.shared.data(from: tokenURL),
                       let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
                       let accessToken = tokenJSON["accessToken"] as? String, !accessToken.isEmpty {
                        var searchReq = URLRequest(url: URL(string: "https://api.spotify.com/v1/search?q=isrc%3A\(isrc)&type=track&limit=1")!)
                        searchReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                        if let (searchData, _) = try? await URLSession.shared.data(for: searchReq),
                           let searchJSON = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                           let tracks = searchJSON["tracks"] as? [String: Any],
                           let items = tracks["items"] as? [[String: Any]],
                           let firstTrack = items.first,
                           let trackID = firstTrack["id"] as? String, !trackID.isEmpty {
                            spotifyURL = "https://open.spotify.com/track/\(trackID)"
                            log("ByeTunes Spotify fallback: anon Spotify token found track: \(spotifyURL!)")
                        }
                    }
                }
            }

            // Path 3: song.link with Apple Music URL → Spotify (last resort)
            if spotifyURL == nil,
               let mapped = try? await fetchMappedURL(for: mappingSeedURL(for: source.url), platform: .spotify) {
                spotifyURL = mapped
                log("ByeTunes Spotify fallback: song.link AM→Spotify: \(mapped)")
            }

            if let spotifyURL {
                candidates.append(try makeCandidate(label: "ByeTunes API (Spotify)", format: desiredFormat, overrideURL: spotifyURL))
                if desiredFormat.lowercased() != "mp3" {
                    candidates.append(try makeCandidate(label: "ByeTunes API (Spotify MP3 Fallback)", format: "mp3", overrideURL: spotifyURL))
                }
            }
        }

        return candidates
    }

    private func appleExtensionCandidates(for source: DownloadSourceChoice) throws -> [BackendCandidate] {
        let codec = "alac"
        let app2Payload = try JSONSerialization.data(withJSONObject: ["url": source.url, "codec": codec])
        var candidates: [BackendCandidate] = []

        if let request = makePOSTRequest(
            label: "Apple Music API (app2)",
            urlString: "https://api.zarz.moe/v1/dl/app2",
            jsonBody: app2Payload
        ) {
            candidates.append(request)
        }

        candidates.append(
            BackendCandidate(
                label: "Apple Music API (app)",
                request: nil,
                tidalAPIBaseURL: nil,
                customDownload: { [weak self] _, suggestedName, _ in
                    guard let self else {
                        throw DownloadError.remoteFailure("Apple Music queued downloader is unavailable.")
                    }
                    return try await self.runAppleQueuedDownload(sourceURL: source.url, codec: codec, suggestedName: suggestedName)
                }
            )
        )

        return candidates
    }

    private func deezerExtensionCandidates(for source: DownloadSourceChoice) throws -> [BackendCandidate] {
        return [
            BackendCandidate(
                label: "Deezer API (Zarz)",
                request: nil,
                tidalAPIBaseURL: nil,
                customDownload: { [weak self] _, suggestedName, _ in
                    guard let self else {
                        throw DownloadError.remoteFailure("Deezer downloader is unavailable.")
                    }
                    return try await self.runDeezerExtensionDownload(sourceURL: source.url, suggestedName: suggestedName)
                }
            )
        ]
    }

    private func tidalExtensionCandidates(for source: DownloadSourceChoice) throws -> [BackendCandidate] {
        let quality = tidalTrackQuality()
        var candidates: [BackendCandidate] = []

        if let trackID = DownloadSupport.tidalTrackID(from: source.url) {
            let idPayload = try JSONSerialization.data(withJSONObject: [
                "id": trackID,
                "quality": quality
            ])
            if let request = makePOSTRequest(
                label: "Tidal API (tid2)",
                urlString: "https://api.zarz.moe/v1/dl/tid2",
                jsonBody: idPayload
            ) {
                candidates.append(request)
            }
        }

        let urlPayload = try JSONSerialization.data(withJSONObject: [
            "url": source.url,
            "quality": quality
        ])
        if let request = makePOSTRequest(
            label: "Tidal API (tid)",
            urlString: "https://api.zarz.moe/v1/dl/tid",
            jsonBody: urlPayload
        ) {
            candidates.append(request)
        }

        return candidates
    }

    private func pandoraExtensionCandidates(for source: DownloadSourceChoice) throws -> [BackendCandidate] {
        let payload = try JSONSerialization.data(withJSONObject: ["url": pandoraResolverInput(from: source.url)])
        return [
            makePOSTRequest(
                label: "Pandora API (Zarz)",
                urlString: "https://api.zarz.moe/v1/dl/pan",
                jsonBody: payload
            )
        ].compactMap { $0 }
    }

    private func amazonExtensionCandidates(for source: DownloadSourceChoice) -> [BackendCandidate] {
        guard let asin = amazonASIN(from: source.url) else { return [] }
        return [
            makeRequest(
                label: "Amazon Music API (Zarz)",
                urlString: "https://api.zarz.moe/v1/dl/amazeamazeamaze/media?asin=\(asin)&codec=flac"
            )
        ].compactMap { $0 }
    }

    private func cobaltExtensionCandidates(for source: DownloadSourceChoice, providerLabel: String) throws -> [BackendCandidate] {
        let payload = try JSONSerialization.data(withJSONObject: [
            "url": source.url,
            "downloadMode": "audio",
            "audioFormat": "best"
        ])
        return [
            makePOSTRequest(
                label: providerLabel,
                urlString: "https://api.zarz.moe/v1/dl/cobalt",
                jsonBody: payload
            )
        ].compactMap { $0 }
    }

    private func runAppleQueuedDownload(sourceURL: String, codec: String, suggestedName: String) async throws -> URL {
        guard let startURL = URL(string: "https://api.zarz.moe/v1/dl/app/download") else {
            throw DownloadError.invalidURL("https://api.zarz.moe/v1/dl/app/download")
        }

        var startRequest = URLRequest(url: startURL)
        startRequest.httpMethod = "POST"
        applyZarzHeaders(to: &startRequest)
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "url": sourceURL,
            "codec": codec
        ])

        let startObject = try await performJSONObjectRequest(startRequest)
        if let immediateURL = extractProviderDownloadURL(from: startObject) {
            return try await executeDownloadRequest(
                URLRequest(url: immediateURL),
                trackID: sourceURL,
                suggestedName: suggestedName,
                fallbackExtension: "m4a"
            )
        }

        guard let jobID = findFirstString(in: startObject, matching: ["job_id", "jobId", "id"]), !jobID.isEmpty else {
            throw DownloadError.remoteFailure("Apple Music queued download did not return a job ID.")
        }

        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 1_500_000_000)

            guard let statusURL = URL(string: "https://api.zarz.moe/v1/dl/app/status/\(jobID)") else {
                throw DownloadError.invalidURL("https://api.zarz.moe/v1/dl/app/status/\(jobID)")
            }
            var statusRequest = URLRequest(url: statusURL)
            applyZarzHeaders(to: &statusRequest)
            let statusObject = try await performJSONObjectRequest(statusRequest)

            if let resolvedURL = extractProviderDownloadURL(from: statusObject) {
                return try await executeDownloadRequest(
                    URLRequest(url: resolvedURL),
                    trackID: sourceURL,
                    suggestedName: suggestedName,
                    fallbackExtension: "m4a"
                )
            }

            if let status = findFirstString(in: statusObject, matching: ["status", "state"])?.lowercased(),
               status.contains("failed") || status.contains("error") {
                throw DownloadError.remoteFailure("Apple Music queued download failed with status '\(status)'.")
            }

            if let ready = findFirstString(in: statusObject, matching: ["status", "state"])?.lowercased(),
               ready.contains("complete") || ready.contains("completed") || ready.contains("success") || ready.contains("done") {
                break
            }
        }

        guard let fileURL = URL(string: "https://api.zarz.moe/v1/dl/app/file/\(jobID)") else {
            throw DownloadError.invalidURL("https://api.zarz.moe/v1/dl/app/file/\(jobID)")
        }
        var fileRequest = URLRequest(url: fileURL)
        applyZarzHeaders(to: &fileRequest)
        return try await executeDownloadRequest(
            fileRequest,
            trackID: sourceURL,
            suggestedName: suggestedName,
            fallbackExtension: "m4a"
        )
    }

    private func performJSONObjectRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw DownloadError.remoteFailure(bodyText)
        }
        return object
    }

    private func runDeezerExtensionDownload(sourceURL: String, suggestedName: String) async throws -> URL {
        if let cachedDescriptor = cachedDeezerDescriptor(for: sourceURL) {
            do {
                let fileURL = try await downloadDeezerDescriptor(cachedDescriptor, suggestedName: suggestedName)
                log("Reused cached Deezer stream URL for \(suggestedName)")
                return fileURL
            } catch {
                clearCachedDeezerDescriptor(for: sourceURL)
                log("Cached Deezer stream URL failed for \(suggestedName): \(error.localizedDescription)")
            }
        }

        guard let resolverURL = URL(string: "https://api.zarz.moe/v1/dl/dzr") else {
            throw DownloadError.invalidURL("https://api.zarz.moe/v1/dl/dzr")
        }

        var request = URLRequest(url: resolverURL)
        request.httpMethod = "POST"
        applyZarzHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "platform": "deezer",
            "url": sourceURL
        ])

        let descriptor = try await performRetryingDeezerResolverRequest(request)
        cacheDeezerDescriptor(descriptor, for: sourceURL)
        return try await downloadDeezerDescriptor(descriptor, suggestedName: suggestedName, fallbackTrackID: deezerTrackID(from: sourceURL))
    }

    private func downloadDeezerDescriptor(
        _ descriptor: [String: Any],
        suggestedName: String,
        fallbackTrackID: String? = nil
    ) async throws -> URL {
        guard let downloadURL = extractProviderDownloadURL(from: descriptor) else {
            throw DownloadError.remoteFailure("Deezer resolver did not return a download URL.")
        }

        let downloadRequest = URLRequest(url: downloadURL)
        let (encryptedData, response) = try await fetchDataWithProgress(for: downloadRequest) { [weak self] progress, speedBps in
            self?.currentSongProgress = progress
            self?.currentDownloadSpeedBps = speedBps
        }
        try validateHTTP(response: response, data: encryptedData)

        let requiresDecryption = findFirstBool(in: descriptor, matching: ["requires_client_decryption", "deezer_encrypted"]) ?? false
        let fileFormat = (findFirstString(in: descriptor, matching: ["deezer_format", "format"]) ?? "flac").lowercased()
        let decryptedData: Data
        if requiresDecryption {
            let trackID = findFirstString(in: descriptor, matching: ["deezer_track_id", "track_id"]) ?? fallbackTrackID
            guard let trackID, let blowfishKey = deezerBlowfishKey(for: trackID) else {
                throw DownloadError.remoteFailure("Deezer download requires decryption, but no track key could be derived.")
            }
            decryptedData = try decryptDeezerStream(encryptedData, key: blowfishKey)
        } else {
            decryptedData = encryptedData
        }

        let mimeType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        let fileExtension = deezerFileExtension(format: fileFormat, mimeType: mimeType)
        return try saveDownloadedData(decryptedData, suggestedName: suggestedName, fileExtension: fileExtension)
    }

    private func performRetryingDeezerResolverRequest(_ request: URLRequest) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(TimeInterval(DeezerResolverPolicy.maxAutomaticWaitSeconds))
        var lastError: Error?

        resolverWindow: while Date() < deadline {
            if let cooldown = deezerResolverCooldownRemaining() {
                let remainingWindow = max(1, Int(ceil(deadline.timeIntervalSinceNow)))
                let waitSeconds = min(cooldown, remainingWindow)
                log("Waiting \(waitSeconds)s for Deezer resolver cooldown before retrying.")
                try await Task.sleep(nanoseconds: UInt64(waitSeconds) * 1_000_000_000)
                continue
            }

            resolverAttempts: for attempt in 1...3 {
                do {
                    return try await performJSONObjectRequest(request)
                } catch {
                    lastError = error
                    if let retryAfter = deezerRetryAfterSeconds(from: error) {
                        rememberDeezerResolverCooldown(seconds: retryAfter)
                        continue resolverWindow
                    }
                    guard attempt < 3, isRetryableDeezerResolverError(error) else {
                        throw error
                    }
                    log("Retrying Deezer resolver after transient failure (\(attempt)/3): \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 750_000_000)
                }
            }
        }

        if let cooldown = deezerResolverCooldownRemaining(), cooldown > 0 {
            throw DownloadError.mappingFailed("Deezer stayed overloaded for several minutes. Try again a bit later.")
        }

        throw lastError ?? DownloadError.remoteFailure("Deezer resolver failed.")
    }

    private func deezerRetryAfterSeconds(from error: Error) -> Int? {
        guard case let DownloadError.httpError(code, body) = error, code == 429 || (500...504).contains(code) else {
            return nil
        }

        guard let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DeezerResolverCooldownPayload.self, from: data),
              let retryAfter = payload.retry_after,
              retryAfter > 0 else {
            return nil
        }
        return retryAfter
    }

    private func isRetryableDeezerResolverError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                break
            }
        }

        guard case let DownloadError.httpError(code, _) = error else {
            return false
        }
        return code == 429 || (500...504).contains(code)
    }

    private func cacheDeezerSourceURL(_ url: String, for trackID: String) {
        guard !trackID.isEmpty, !url.isEmpty else { return }
        UserDefaults.standard.set(url, forKey: "deezerSourceURL.\(trackID)")
    }

    private func cachedDeezerSourceURL(for trackID: String) -> String? {
        guard !trackID.isEmpty else { return nil }
        return UserDefaults.standard.string(forKey: "deezerSourceURL.\(trackID)")
    }

    private func cacheDeezerDescriptor(_ descriptor: [String: Any], for sourceURL: String) {
        guard !sourceURL.isEmpty,
              let downloadURL = extractProviderDownloadURL(from: descriptor)?.absoluteString else { return }

        let payload = CachedDeezerDescriptor(
            downloadURL: downloadURL,
            requiresClientDecryption: findFirstBool(in: descriptor, matching: ["requires_client_decryption", "deezer_encrypted"]) ?? false,
            fileFormat: (findFirstString(in: descriptor, matching: ["deezer_format", "format"]) ?? "flac").lowercased(),
            trackID: findFirstString(in: descriptor, matching: ["deezer_track_id", "track_id"]) ?? deezerTrackID(from: sourceURL),
            cachedAt: Date()
        )

        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: "deezerDescriptor.\(sourceURL)")
    }

    private func cachedDeezerDescriptor(for sourceURL: String) -> [String: Any]? {
        guard !sourceURL.isEmpty,
              let data = UserDefaults.standard.data(forKey: "deezerDescriptor.\(sourceURL)"),
              let payload = try? JSONDecoder().decode(CachedDeezerDescriptor.self, from: data) else {
            return nil
        }

        if Date().timeIntervalSince(payload.cachedAt) > 900 {
            clearCachedDeezerDescriptor(for: sourceURL)
            return nil
        }

        var descriptor: [String: Any] = [
            "direct_download_url": payload.downloadURL,
            "download_url": payload.downloadURL,
            "requires_client_decryption": payload.requiresClientDecryption,
            "deezer_format": payload.fileFormat
        ]
        if let trackID = payload.trackID, !trackID.isEmpty {
            descriptor["track_id"] = trackID
            descriptor["deezer_track_id"] = trackID
        }
        return descriptor
    }

    private func clearCachedDeezerDescriptor(for sourceURL: String) {
        guard !sourceURL.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: "deezerDescriptor.\(sourceURL)")
    }

    private func rememberDeezerResolverCooldown(seconds: Int) {
        let safeSeconds = max(seconds, 1)
        let until = Date().addingTimeInterval(TimeInterval(safeSeconds))
        UserDefaults.standard.set(until, forKey: "deezerResolverCooldownUntil")
    }

    private func deezerResolverCooldownRemaining() -> Int? {
        guard let until = UserDefaults.standard.object(forKey: "deezerResolverCooldownUntil") as? Date else {
            return nil
        }
        let remaining = Int(ceil(until.timeIntervalSinceNow))
        return remaining > 0 ? remaining : nil
    }

    private func amazonASIN(from urlString: String) -> String? {
        let patterns = [
            #"/([A-Z0-9]{10})(?:[/?]|$)"#,
            #"asin=([A-Z0-9]{10})(?:[&]|$)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: urlString, range: NSRange(location: 0, length: urlString.utf16.count)),
               let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }

    private func pandoraResolverInput(from urlString: String) -> String {
        guard let tokenRange = urlString.range(of: #"/(TR[A-Za-z0-9]+)"#, options: .regularExpression) else {
            return urlString
        }

        let token = String(urlString[tokenRange]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let match = token.range(of: #"^([A-Za-z]+)(\d+)"#, options: .regularExpression) else {
            return urlString
        }

        let prefixDigits = String(token[match])
        let letters = prefixDigits.prefix { $0.isLetter }
        let digits = prefixDigits.drop { $0.isLetter }
        guard !letters.isEmpty, !digits.isEmpty else { return urlString }
        return "\(letters):\(digits)"
    }

    private func deezerTrackID(from urlString: String) -> String? {
        guard let range = urlString.range(of: "/track/") else { return nil }
        let tail = urlString[range.upperBound...]
        let value = tail.split(separator: "?").first?.split(separator: "/").first.map(String.init) ?? ""
        return value.isEmpty ? nil : value
    }

    private func deezerFileExtension(format: String, mimeType: String?) -> String {
        if format.contains("flac") { return "flac" }
        if format.contains("mp3") { return "mp3" }
        return DownloadSupport.fileExtension(for: mimeType, fallback: "flac")
    }

    private func deezerBlowfishKey(for trackID: String) -> Data? {
        let digest = Insecure.MD5.hash(data: Data(trackID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let secret = Array("g4el58wc0zvf9na1".utf8)
        let md5Bytes = Array(hex.utf8)
        guard md5Bytes.count >= 32, secret.count == 16 else { return nil }

        var keyBytes = [UInt8]()
        keyBytes.reserveCapacity(16)
        for index in 0..<16 {
            keyBytes.append(md5Bytes[index] ^ md5Bytes[index + 16] ^ secret[index])
        }
        return Data(keyBytes)
    }

    private func decryptDeezerStream(_ encryptedData: Data, key: Data) throws -> Data {
        let chunkSize = 2048
        let iv = Data([0, 1, 2, 3, 4, 5, 6, 7])
        var output = Data(capacity: encryptedData.count)
        var offset = 0
        var chunkIndex = 0

        while offset < encryptedData.count {
            let end = min(offset + chunkSize, encryptedData.count)
            let chunk = encryptedData[offset..<end]

            if chunkIndex % 3 == 0 && chunk.count == chunkSize {
                output.append(try blowfishCBCDecrypt(Data(chunk), key: key, iv: iv))
            } else {
                output.append(chunk)
            }

            offset = end
            chunkIndex += 1
        }

        return output
    }

    private func blowfishCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var outLength = 0
        var outData = Data(count: data.count + kCCBlockSizeBlowfish)
        let outCapacity = outData.count
        let status = outData.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmBlowfish),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw DownloadError.remoteFailure("Deezer Blowfish decryption failed (\(status)).")
        }

        outData.count = outLength
        return outData
    }

    private func yoinkifyCompatibleSource(for track: DownloadTrack) async -> DownloadSourceChoice? {
        let query = "\(track.artistLine) \(track.name)"
        let candidates = await AppleMusicAPI.shared.searchSongs(query: query, limit: 10, offset: 0)
        if !candidates.isEmpty {
            let ranked = candidates
                .map { candidate in
                    (candidate, scoreAppleMusicCandidate(candidate, for: track))
                }
                .sorted {
                    if $0.1 == $1.1 {
                        return $0.0.id < $1.0.id
                    }
                    return $0.1 > $1.1
                }

            if let best = ranked.first, best.1 >= 120 {
                let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
                let url = best.0.attributes.url ?? "https://music.apple.com/\(region)/song/\(best.0.id)"
                return DownloadSourceChoice(platform: .appleMusic, url: url, backendGenreSource: DownloadPlatform.appleMusic.backendGenreSource)
            }
        }

        if let fallback = await bestMetadataFallback(for: track), let source = fallback.source {
            log("Using \(fallback.providerName) metadata fallback for Yoinkify remap: \(fallback.artist) - \(fallback.title)")
            return source
        }

        return nil
    }

    private func scoreAppleMusicCandidate(_ candidate: AppleMusicAPI.AppleMusicSong, for track: DownloadTrack) -> Int {
        let trackTitle = DownloadSupport.normalizedSearchValue(track.name)
        let trackAlbum = DownloadSupport.normalizedSearchValue(track.albumName)
        let candidateTitle = DownloadSupport.normalizedSearchValue(candidate.attributes.name)
        let candidateAlbum = DownloadSupport.normalizedSearchValue(candidate.attributes.albumName ?? "")
        let candidateArtists = DownloadSupport.artistTokens(from: candidate.attributes.artistName)
        let sourceArtists = DownloadSupport.artistTokens(from: track.artistLine)

        var score = 0

        if candidateTitle == trackTitle {
            score += 140
        } else if candidateTitle.contains(trackTitle) || trackTitle.contains(candidateTitle) {
            score += 95
        }

        for artist in sourceArtists {
            if candidateArtists.contains(artist) {
                score += 35
            } else if candidateArtists.contains(where: { $0.contains(artist) || artist.contains($0) }) {
                score += 20
            }
        }

        if !trackAlbum.isEmpty, trackAlbum != "unknown album" {
            if candidateAlbum == trackAlbum {
                score += 40
            } else if candidateAlbum.contains(trackAlbum) || trackAlbum.contains(candidateAlbum) {
                score += 18
            }
        }

        return score
    }

    private func bestMetadataFallback(for track: DownloadTrack) async -> DownloadMetadataFallbackMatch? {
        let query = "\(track.artistLine) \(track.name)"
        var matches: [(match: DownloadMetadataFallbackMatch, score: Int)] = []

        let iTunesResults = await SongMetadata.searchiTunes(query: query)
        for candidate in iTunesResults {
            guard let title = candidate.trackName,
                  let artist = candidate.artistName else { continue }

            let source: DownloadSourceChoice?
            if let url = candidate.trackViewUrl, !url.isEmpty {
                source = DownloadSourceChoice(platform: .appleMusic, url: url, backendGenreSource: DownloadPlatform.appleMusic.backendGenreSource)
            } else {
                source = nil
            }

            let match = DownloadMetadataFallbackMatch(
                title: title,
                artist: artist,
                album: candidate.collectionName,
                source: source,
                providerName: "iTunes"
            )
            matches.append((match, scoreMetadataFallback(title: title, artist: artist, album: candidate.collectionName, for: track)))
        }

        let deezerResults = await SongMetadata.searchDeezer(query: query)
        for candidate in deezerResults {
            let source: DownloadSourceChoice?
            if let url = candidate.link, !url.isEmpty {
                source = DownloadSourceChoice(platform: .deezer, url: url, backendGenreSource: DownloadPlatform.deezer.backendGenreSource)
            } else {
                source = nil
            }

            let match = DownloadMetadataFallbackMatch(
                title: candidate.title,
                artist: candidate.artist.name,
                album: candidate.album.title,
                source: source,
                providerName: "Deezer"
            )
            matches.append((match, scoreMetadataFallback(title: candidate.title, artist: candidate.artist.name, album: candidate.album.title, for: track)))
        }

        let ranked = matches.sorted {
            if $0.score == $1.score {
                return $0.match.providerName < $1.match.providerName
            }
            return $0.score > $1.score
        }

        guard let best = ranked.first, best.score >= 115 else {
            return nil
        }

        return best.match
    }

    private func scoreMetadataFallback(title: String, artist: String, album: String?, for track: DownloadTrack) -> Int {
        let trackTitle = DownloadSupport.normalizedSearchValue(track.name)
        let trackAlbum = DownloadSupport.normalizedSearchValue(track.albumName)
        let candidateTitle = DownloadSupport.normalizedSearchValue(title)
        let candidateAlbum = DownloadSupport.normalizedSearchValue(album ?? "")
        let candidateArtists = DownloadSupport.artistTokens(from: artist)
        let sourceArtists = DownloadSupport.artistTokens(from: track.artistLine)

        var score = 0

        if candidateTitle == trackTitle {
            score += 140
        } else if candidateTitle.contains(trackTitle) || trackTitle.contains(candidateTitle) {
            score += 90
        }

        for artist in sourceArtists {
            if candidateArtists.contains(artist) {
                score += 35
            } else if candidateArtists.contains(where: { $0.contains(artist) || artist.contains($0) }) {
                score += 20
            }
        }

        if !trackAlbum.isEmpty, trackAlbum != "unknown album" {
            if candidateAlbum == trackAlbum {
                score += 35
            } else if candidateAlbum.contains(trackAlbum) || trackAlbum.contains(candidateAlbum) {
                score += 15
            }
        }

        return score
    }

    private func resolveDeezerSource(for track: DownloadTrack) async -> DownloadSourceChoice? {
        let appleSong = await AppleMusicAPI.shared.fetchSong(id: track.id)
        let metadataFallback = appleSong == nil ? await bestMetadataFallback(for: track) : nil
        let searchQueries = buildTidalSearchQueries(for: track, appleSong: appleSong, metadataFallback: metadataFallback)
        let exactISRC = appleSong?.attributes.isrc?.trimmingCharacters(in: .whitespacesAndNewlines)

        var deezerResults: [DeezerSong] = []
        var seenIDs = Set<Int>()
        for query in searchQueries {
            let results = await SongMetadata.searchDeezer(query: query, limit: 10, index: 0)
            for candidate in results where seenIDs.insert(candidate.id).inserted {
                deezerResults.append(candidate)
            }
            if !deezerResults.isEmpty {
                break
            }
        }

        let ranked = deezerResults
            .map { candidate in
                (
                    candidate,
                    scoreDeezerCandidate(candidate, for: track, exactISRC: exactISRC)
                )
            }
            .sorted {
                if $0.1 == $1.1 {
                    return ($0.0.rank ?? 0) > ($1.0.rank ?? 0)
                }
                return $0.1 > $1.1
            }

        guard let best = ranked.first, best.1 >= 120 else { return nil }
        let url = best.0.link ?? "https://www.deezer.com/track/\(best.0.id)"
        return DownloadSourceChoice(
            platform: .deezer,
            url: url,
            backendGenreSource: DownloadPlatform.deezer.backendGenreSource
        )
    }

    private func resolveExactDeezerSource(
        for track: DownloadTrack,
        source: DownloadSourceChoice
    ) async -> DownloadSourceChoice? {
        guard source.platform == .appleMusic || source.platform == .spotify else {
            return nil
        }

        guard track.id.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let appleSong = await AppleMusicAPI.shared.fetchSong(id: track.id),
              let isrc = appleSong.attributes.isrc?.trimmingCharacters(in: .whitespacesAndNewlines),
              !isrc.isEmpty,
              let deezerSong = await SongMetadata.fetchDeezerTrackByISRC(isrc) else {
            return nil
        }

        let score = scoreDeezerCandidate(deezerSong, for: track, exactISRC: isrc)
        let sourcePrimaryArtist = DownloadSupport.normalizedSearchValue(primaryArtistName(from: track.artistLine))
        let deezerPrimaryArtist = DownloadSupport.normalizedSearchValue(deezerSong.artist.name)
        let sourceTitle = DownloadSupport.normalizedSearchValue(simplifiedTrackTitle(track.name))
        let deezerTitle = DownloadSupport.normalizedSearchValue(simplifiedTrackTitle(deezerSong.title))

        guard sourcePrimaryArtist == deezerPrimaryArtist else {
            log("Rejected Deezer ISRC match for \(track.name): artist mismatch \(deezerSong.artist.name)")
            return nil
        }

        guard sourceTitle == deezerTitle || deezerTitle.contains(sourceTitle) || sourceTitle.contains(deezerTitle) else {
            log("Rejected Deezer ISRC match for \(track.name): title mismatch \(deezerSong.title)")
            return nil
        }

        guard score >= 240 else { return nil }

        let url = deezerSong.link ?? "https://www.deezer.com/track/\(deezerSong.id)"
        return DownloadSourceChoice(
            platform: .deezer,
            url: url,
            backendGenreSource: DownloadPlatform.deezer.backendGenreSource
        )
    }

    private func scoreDeezerCandidate(_ candidate: DeezerSong, for track: DownloadTrack, exactISRC: String?) -> Int {
        var score = scoreMetadataFallback(
            title: candidate.title,
            artist: candidate.artist.name,
            album: candidate.album.title,
            for: track
        )

        let candidateISRC = candidate.isrc?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedISRC = exactISRC?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let candidateISRC, let expectedISRC, !candidateISRC.isEmpty, candidateISRC == expectedISRC {
            score += 120
        }

        let primaryArtist = DownloadSupport.normalizedSearchValue(primaryArtistName(from: track.artistLine))
        let candidateArtist = DownloadSupport.normalizedSearchValue(candidate.artist.name)
        if candidateArtist == primaryArtist {
            score += 35
        }

        let simplifiedTrack = DownloadSupport.normalizedSearchValue(simplifiedTrackTitle(track.name))
        let candidateTitle = DownloadSupport.normalizedSearchValue(candidate.title)
        if candidateTitle == simplifiedTrack {
            score += 20
        }

        return score
    }

    private func yoinkifyFormat(for serverPreference: DownloaderServerPreference) -> String {
        // Always respect the user's explicit "Output Format" setting.
        // The autoDownloadTier quality profile path was bypassing the user's choice
        // because downloadWithFallbacks always passes .auto as the server preference.
        return UserDefaults.standard.string(forKey: "yoinkifyFormat") ?? "flac"
    }

    private func qobuzQuality(for serverPreference: DownloaderServerPreference) -> String {
        if serverPreference == .auto {
            switch DownloaderAutomaticQualityProfile(rawValue: UserDefaults.standard.string(forKey: "autoDownloadTier") ?? "") ?? .high {
            case .low:
                return QobuzQualityProfile.lossless.rawValue
            case .medium:
                return QobuzQualityProfile.hiRes.rawValue
            case .high:
                return QobuzQualityProfile.hiResMax.rawValue
            }
        }

        return UserDefaults.standard.string(forKey: "qobuzFallbackQuality") ?? QobuzQualityProfile.hiResMax.rawValue
    }

    private func yoinkProofOfWork(difficulty: Int = 16) async -> [String: Any]? {
        let challengeData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let challenge = challengeData.map { String(format: "%02x", $0) }.joined()
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)

        var nonce = 0
        while nonce < Int.max {
            let input = Data("\(challenge):\(nonce)".utf8)
            let digest = SHA256.hash(data: input)
            if hasLeadingZeroBits(digest, count: difficulty) {
                let hash = digest.map { String(format: "%02x", $0) }.joined()
                log("Yoinkify proof-of-work solved at nonce \(nonce)")
                return [
                    "challenge": challenge,
                    "nonce": nonce,
                    "hash": hash,
                    "timestamp": timestamp
                ]
            }

            nonce += 1
            if nonce.isMultiple(of: 1_000) {
                await Task.yield()
            }
        }

        log("Yoinkify proof-of-work could not be solved.")
        return nil
    }

    private func hasLeadingZeroBits(_ digest: SHA256.Digest, count: Int) -> Bool {
        let bytes = Array(digest)
        let fullBytes = count / 8
        let remainingBits = count % 8

        for index in 0..<fullBytes {
            guard bytes[index] == 0 else { return false }
        }

        guard remainingBits > 0 else { return true }
        let mask = UInt8(0xFF << (8 - remainingBits))
        return (bytes[fullBytes] & mask) == 0
    }

    private func resolveTidalFallbackTrackIDs(for track: DownloadTrack) async -> [String] {
        var orderedTrackIDs: [String] = []
        var seenTrackIDs = Set<String>()

        func appendTrackID(_ trackID: String, reason: String) {
            guard !trackID.isEmpty, seenTrackIDs.insert(trackID).inserted else { return }
            orderedTrackIDs.append(trackID)
            log("Queued Tidal fallback candidate \(trackID) via \(reason)")
        }

        do {
            let mappedURL = try await fetchMappedURL(for: mappingSeedURL(for: track.sourceURL), platform: .tidal)
            log("Mapped Tidal URL: \(mappedURL)")
            if let mappedTrackID = DownloadSupport.tidalTrackID(from: mappedURL) {
                appendTrackID(mappedTrackID, reason: "Song.link")
            } else {
                log("Song.link returned a Tidal URL, but no track ID could be extracted.")
            }
        } catch {
            log("Song.link mapping failed for \(track.name): \(error.localizedDescription)")
        }

        let appleSong = await AppleMusicAPI.shared.fetchSong(id: track.id)
        let metadataFallback = appleSong == nil ? await bestMetadataFallback(for: track) : nil
        let searchQueries = buildTidalSearchQueries(for: track, appleSong: appleSong, metadataFallback: metadataFallback)

        if let appleSong {
            let traits = appleSong.attributes.audioTraits?.joined(separator: ", ") ?? "none"
            log("Matching from Apple metadata: isrc=\(appleSong.attributes.isrc ?? "none"), album=\(appleSong.attributes.albumName ?? "unknown"), traits=\(traits)")
        } else if let metadataFallback {
            log("Matching from \(metadataFallback.providerName) metadata fallback: album=\(metadataFallback.album ?? "unknown")")
        } else {
            log("Direct Apple metadata fetch unavailable for \(track.id). Falling back to visible search metadata only.")
        }

        for query in searchQueries {
            let matchedTrackIDs = await searchTidalCandidateTrackIDs(
                for: track,
                query: query,
                excluding: seenTrackIDs
            )
            for matchedTrackID in matchedTrackIDs {
                appendTrackID(matchedTrackID, reason: "query '\(query)'")
            }
        }

        return orderedTrackIDs
    }

    private func resolveQobuzFallbackTrackIDs(for track: DownloadTrack) async -> [String] {
        var orderedTrackIDs: [String] = []
        var seenTrackIDs = Set<String>()

        func appendTrackID(_ trackID: String, reason: String) {
            guard !trackID.isEmpty, seenTrackIDs.insert(trackID).inserted else { return }
            orderedTrackIDs.append(trackID)
            log("Queued Qobuz fallback candidate \(trackID) via \(reason)")
        }

        do {
            let mappedURL = try await fetchMappedURL(for: mappingSeedURL(for: track.sourceURL), platform: .qobuz)
            log("Mapped Qobuz URL: \(mappedURL)")
            if let mappedTrackID = DownloadSupport.qobuzTrackID(from: mappedURL) {
                appendTrackID(mappedTrackID, reason: "Song.link")
                return orderedTrackIDs
            } else {
                log("Song.link returned a Qobuz URL, but no track ID could be extracted.")
            }
        } catch {
            log("Song.link Qobuz mapping failed for \(track.name): \(error.localizedDescription)")
        }

        let appleSong = await AppleMusicAPI.shared.fetchSong(id: track.id)
        let metadataFallback = appleSong == nil ? await bestMetadataFallback(for: track) : nil
        let searchQueries = buildTidalSearchQueries(for: track, appleSong: appleSong, metadataFallback: metadataFallback)

        if let appleSong {
            let traits = appleSong.attributes.audioTraits?.joined(separator: ", ") ?? "none"
            log("Matching from Apple metadata for Qobuz: isrc=\(appleSong.attributes.isrc ?? "none"), album=\(appleSong.attributes.albumName ?? "unknown"), traits=\(traits)")
        } else if let metadataFallback {
            log("Matching from \(metadataFallback.providerName) metadata fallback for Qobuz: album=\(metadataFallback.album ?? "unknown")")
        } else {
            log("Direct Apple metadata fetch unavailable for \(track.id). Falling back to visible search metadata only for Qobuz.")
        }

        let exactISRC = appleSong?.attributes.isrc?.trimmingCharacters(in: .whitespacesAndNewlines)
        for query in searchQueries {
            let outcome = await searchQobuzCandidateTrackIDs(
                for: track,
                query: query,
                excluding: seenTrackIDs
            )
            for matchedTrackID in outcome.trackIDs {
                appendTrackID(matchedTrackID, reason: "query '\(query)'")
            }

            if let exactISRC,
               !exactISRC.isEmpty,
               query.compare(exactISRC, options: .caseInsensitive) == .orderedSame,
               !outcome.trackIDs.isEmpty {
                log("Qobuz ISRC search produced a usable match. Stopping early.")
                return orderedTrackIDs
            }

            if outcome.bestScore >= 230, !outcome.trackIDs.isEmpty {
                log("Qobuz found a strong exact match for '\(query)'. Stopping early.")
                return orderedTrackIDs
            }
        }

        return orderedTrackIDs
    }

    private func qobuzCandidates(trackID: String) async throws -> [BackendCandidate] {
        let quality = qobuzQuality(for: DownloaderServerPreference(rawValue: UserDefaults.standard.string(forKey: "downloadServer") ?? "") ?? .auto)
        let payload = try makeQobuzDownloadPayload(trackID: trackID, quality: quality)
        return QobuzAPIRegistry.downloadProviders.compactMap { provider in
            guard let url = URL(string: provider.url) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload
            return BackendCandidate(
                label: provider.label,
                request: request,
                tidalAPIBaseURL: nil,
                customDownload: nil
            )
        }
    }

    private func makeQobuzDownloadPayload(trackID: String, quality: String) throws -> Data {
        let payload: [String: Any] = [
            "quality": quality,
            "upload_to_r2": false,
            "url": "https://open.qobuz.com/track/\(trackID)"
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func tidalCandidates(trackID: String) async -> [BackendCandidate] {
        let quality = tidalTrackQuality()
        let backends = await rotatedTidalTrackBackends()
        return backends.compactMap { backend in
            makeRequest(
                label: backend.label,
                urlString: "\(backend.baseURL)/track/?id=\(trackID)&quality=\(quality)",
                tidalAPIBaseURL: backend.baseURL
            )
        }
    }

    private func tidalCandidates(trackID: String, preference: DownloaderServerPreference) async -> [BackendCandidate] {
        let quality = tidalTrackQuality()
        switch preference {
        case .hifiOne:
            return await preferredTidalCandidates(
                trackID: trackID,
                quality: quality,
                preferredBaseURL: "https://hifi-one.spotisaver.net",
                preferredLabel: "HiFi One"
            )
        case .hifiTwo:
            return await preferredTidalCandidates(
                trackID: trackID,
                quality: quality,
                preferredBaseURL: "https://hifi-two.spotisaver.net",
                preferredLabel: "HiFi Two"
            )
        case .byeTunesAPI, .qobuz, .appleMusicAPI, .deezerAPI, .pandoraAPI, .amazonAPI, .soundCloudAPI, .youtubeAPI:
            return []
        case .auto, .yoinkify, .tidalAPI:
            return await tidalCandidates(trackID: trackID)
        }
    }

    private func tidalTrackQuality() -> String {
        let serverPreference = DownloaderServerPreference(rawValue: UserDefaults.standard.string(forKey: "downloadServer") ?? "") ?? .auto
        if serverPreference == .auto {
            switch DownloaderAutomaticQualityProfile(rawValue: UserDefaults.standard.string(forKey: "autoDownloadTier") ?? "") ?? .high {
            case .low:
                return "LOW"
            case .medium:
                return "HIGH"
            case .high:
                return "LOSSLESS"
            }
        }
        return UserDefaults.standard.string(forKey: "tidalFallbackQuality") ?? "LOSSLESS"
    }

    private func rotatedTidalTrackBackends() async -> [(label: String, baseURL: String)] {
        let fallback = TidalAPIRegistry.defaultBaseURLs
        let fetched = await fetchRemoteTidalAPIBaseURLs()
        let cached = loadCachedTidalAPIBaseURLs()

        let merged = normalizeTidalAPIBaseURLs(fetched + cached + fallback)
        if merged != cached {
            saveCachedTidalAPIBaseURLs(merged)
        }

        let rotated = rotateTidalAPIBaseURLs(
            merged.isEmpty ? fallback : merged,
            lastUsed: UserDefaults.standard.string(forKey: TidalAPIRegistry.lastUsedKey)
        )

        return rotated.map { baseURL in
            let host = URL(string: baseURL)?.host ?? baseURL
            return (label: "Tidal API (\(host))", baseURL: baseURL)
        }
    }

    private func rotatedTidalSearchHosts() async -> [String] {
        var searchHosts = await rotatedTidalTrackBackends().map { "\($0.baseURL)/search/" }

        if let activeTidalSearchHost,
           let index = searchHosts.firstIndex(of: activeTidalSearchHost) {
            let preferred = searchHosts.remove(at: index)
            searchHosts.insert(preferred, at: 0)
        }

        return searchHosts
    }

    private func fetchRemoteTidalAPIBaseURLs() async -> [String] {
        guard let url = URL(string: TidalAPIRegistry.gistURL) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, response) = try await session.data(for: request)
            try validateHTTP(response: response, data: data)
            let decoded = try JSONDecoder().decode([String].self, from: data)
            let normalized = normalizeTidalAPIBaseURLs(decoded)
            if !normalized.isEmpty {
                log("Loaded \(normalized.count) rotating Tidal API base URLs from gist.")
            }
            return normalized
        } catch {
            log("Failed to refresh rotating Tidal API list: \(error.localizedDescription)")
            return []
        }
    }

    private func loadCachedTidalAPIBaseURLs() -> [String] {
        guard let cached = UserDefaults.standard.array(forKey: TidalAPIRegistry.cacheKey) as? [String] else {
            return []
        }
        return normalizeTidalAPIBaseURLs(cached)
    }

    private func saveCachedTidalAPIBaseURLs(_ urls: [String]) {
        UserDefaults.standard.set(urls, forKey: TidalAPIRegistry.cacheKey)
    }

    private func normalizeTidalAPIBaseURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for raw in urls {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let value = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
            guard let host = URL(string: value)?.host, !host.isEmpty else { continue }
            guard seen.insert(value).inserted else { continue }
            normalized.append(value)
        }

        return normalized
    }

    private func rotateTidalAPIBaseURLs(_ urls: [String], lastUsed: String?) -> [String] {
        guard let lastUsed, !lastUsed.isEmpty else { return urls }
        guard let lastIndex = urls.firstIndex(of: lastUsed) else { return urls }
        let nextIndex = urls.index(after: lastIndex)
        let head = nextIndex < urls.endIndex ? Array(urls[nextIndex...]) : []
        let tail = Array(urls[...lastIndex])
        return head + tail
    }

    private func rememberTidalAPIBaseURLSuccess(_ baseURL: String) {
        UserDefaults.standard.set(baseURL, forKey: TidalAPIRegistry.lastUsedKey)
    }

    private func preferredTidalCandidates(
        trackID: String,
        quality: String,
        preferredBaseURL: String,
        preferredLabel: String
    ) async -> [BackendCandidate] {
        let rotated = await rotatedTidalTrackBackends().map(\.baseURL)
        let orderedBaseURLs = normalizeTidalAPIBaseURLs([preferredBaseURL] + rotated)
        return orderedBaseURLs.compactMap { baseURL in
            let label: String
            if baseURL == preferredBaseURL {
                label = preferredLabel
            } else {
                label = "Tidal API (\(URL(string: baseURL)?.host ?? baseURL))"
            }

            return makeRequest(
                label: label,
                urlString: "\(baseURL)/track/?id=\(trackID)&quality=\(quality)",
                tidalAPIBaseURL: baseURL
            )
        }
    }

    private func executeCandidatesUntilSuccess(
        _ candidates: [BackendCandidate],
        trackID: String,
        suggestedName: String,
        fallbackExtension: String
    ) async throws -> BackendDownloadOutcome? {
        guard !candidates.isEmpty else {
            throw DownloadError.mappingFailed("No usable backend request was created.")
        }

        var lastError: Error = DownloadError.mappingFailed("All backend requests failed.")

        for candidate in candidates {
            do {
                let fileURL: URL
                if let customDownload = candidate.customDownload {
                    fileURL = try await customDownload(trackID, suggestedName, fallbackExtension)
                } else if let request = candidate.request {
                    fileURL = try await executeDownloadRequest(
                        request,
                        trackID: trackID,
                        suggestedName: suggestedName,
                        fallbackExtension: fallbackExtension
                    )
                } else {
                    throw DownloadError.mappingFailed("No usable backend request was created for \(candidate.label).")
                }
                if let tidalAPIBaseURL = candidate.tidalAPIBaseURL {
                    rememberTidalAPIBaseURLSuccess(tidalAPIBaseURL)
                }
                log("\(candidate.label) backend succeeded.")
                BackendHealthStore.shared.recordSuccess(label: candidate.label)
                return BackendDownloadOutcome(fileURL: fileURL, backendLabel: candidate.label)
            } catch {
                lastError = error
                log("\(candidate.label) backend failed: \(error.localizedDescription)")
                BackendHealthStore.shared.recordFailure(label: candidate.label, error: error.localizedDescription)
            }
        }

        throw lastError
    }

    private func executeDownloadRequest(
        _ request: URLRequest,
        trackID: String,
        suggestedName: String,
        fallbackExtension: String,
        depth: Int = 0
    ) async throws -> URL {
        if depth > 4 {
            throw DownloadError.mappingFailed("Too many redirect/manifest hops.")
        }

        var request = request
        applyZarzHeaders(to: &request)
        log("Requesting \(redactedDownloadURLString(request.url))")

        let (data, response) = try await fetchDataWithProgress(for: request) { [weak self] progress, speedBps in
            self?.currentSongProgress = progress
            self?.currentDownloadSpeedBps = speedBps
        }
        try validateHTTP(response: response, data: data)

        if let manifestURL = extractManifestURL(from: data) {
            log("Resolved manifest media URL: \(redactedDownloadURLString(manifestURL))")
            let redirectedRequest = URLRequest(url: manifestURL)
            return try await executeDownloadRequest(
                redirectedRequest,
                trackID: trackID,
                suggestedName: suggestedName,
                fallbackExtension: fallbackExtension,
                depth: depth + 1
            )
        }

        if let redirectedURL = extractRedirectURL(from: data) {
            log("Received JSON redirect: \(redactedDownloadURLString(redirectedURL))")
            let redirectedRequest = URLRequest(url: redirectedURL)
            return try await executeDownloadRequest(
                redirectedRequest,
                trackID: trackID,
                suggestedName: suggestedName,
                fallbackExtension: fallbackExtension,
                depth: depth + 1
            )
        }

        let httpResponse = response as? HTTPURLResponse
        let mimeType = httpResponse?.value(forHTTPHeaderField: "Content-Type")

        guard !data.isEmpty else {
            throw DownloadError.emptyResponse
        }

        if let mimeType, mimeType.contains("application/json"), extractRedirectURL(from: data) == nil {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 json>"
            throw DownloadError.remoteFailure(bodyText)
        }

        let fileExtension = DownloadSupport.fileExtension(for: mimeType, fallback: fallbackExtension)
        return try saveDownloadedData(data, suggestedName: suggestedName, fileExtension: fileExtension)
    }

    private func redactedDownloadURLString(_ url: URL?) -> String {
        guard let url else { return "<unknown>" }
        if url.host?.caseInsensitiveCompare(Config.byeTunesApiHost) == .orderedSame {
            return "ByeTunes API"
        }
        return url.absoluteString
    }

    private func validateHTTP(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw DownloadError.httpError(http.statusCode, body)
        }
    }

    private func extractManifestURL(from data: Data) -> URL? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let manifest = findFirstString(in: obj, matching: ["manifest"]),
           let resolved = decodeManifestMediaURL(manifest) {
            return resolved
        }

        if let direct = findFirstURLString(
            in: obj,
            matching: ["manifest_url", "manifestUrl", "stream_url", "streamUrl", "media_url", "mediaUrl"]
        ), let url = URL(string: direct) {
            return url
        }

        return nil
    }

    private func decodeManifestMediaURL(_ manifest: String) -> URL? {
        let candidates = [manifest, manifest.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")]
        for candidate in candidates {
            let padded = padBase64(candidate)
            guard let data = Data(base64Encoded: padded) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let urls = obj["urls"] as? [String], let first = urls.first, let url = URL(string: first) {
                return url
            }
            let keys = ["url", "manifest_url", "media_url"]
            for key in keys {
                if let value = obj[key] as? String, let url = URL(string: value) {
                    return url
                }
            }
        }
        return nil
    }

    private func extractProviderDownloadURL(from object: [String: Any]) -> URL? {
        if let manifest = findFirstString(in: object, matching: ["manifest"]),
           let decoded = decodeManifestMediaURL(manifest) {
            return decoded
        }

        if let direct = findFirstURLString(
            in: object,
            matching: [
                "stream_url",
                "streamUrl",
                "direct_download_url",
                "directDownloadUrl",
                "download_url",
                "downloadUrl",
                "media_url",
                "mediaUrl",
                "url",
                "link"
            ]
        ), let url = URL(string: direct) {
            return url
        }

        return nil
    }

    private func findFirstURLString(in object: Any, matching preferredKeys: [String]) -> String? {
        for key in preferredKeys {
            if let value = findFirstString(in: object, matching: [key]), URL(string: value) != nil {
                return value
            }
        }

        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let match = findFirstURLString(in: value, matching: preferredKeys) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findFirstURLString(in: value, matching: preferredKeys) {
                    return match
                }
            }
        } else if let string = object as? String, URL(string: string) != nil {
            return string
        }

        return nil
    }

    private func findFirstString(in object: Any, matching keys: [String]) -> String? {
        let normalizedKeys = Set(keys.map { $0.lowercased() })

        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if normalizedKeys.contains(key.lowercased()), let stringValue = value as? String, !stringValue.isEmpty {
                    return stringValue
                }
            }

            for value in dictionary.values {
                if let match = findFirstString(in: value, matching: keys) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findFirstString(in: value, matching: keys) {
                    return match
                }
            }
        }

        return nil
    }

    private func findFirstBool(in object: Any, matching keys: [String]) -> Bool? {
        let normalizedKeys = Set(keys.map { $0.lowercased() })

        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                guard normalizedKeys.contains(key.lowercased()) else { continue }
                if let boolValue = value as? Bool {
                    return boolValue
                }
                if let stringValue = value as? String {
                    switch stringValue.lowercased() {
                    case "true", "1", "yes":
                        return true
                    case "false", "0", "no":
                        return false
                    default:
                        break
                    }
                }
                if let intValue = value as? Int {
                    return intValue != 0
                }
            }

            for value in dictionary.values {
                if let match = findFirstBool(in: value, matching: keys) {
                    return match
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let match = findFirstBool(in: value, matching: keys) {
                    return match
                }
            }
        }

        return nil
    }

    private func padBase64(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder != 0 else { return value }
        return value + String(repeating: "=", count: 4 - remainder)
    }

    private func extractRedirectURL(from data: Data) -> URL? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let value = findFirstURLString(
            in: obj,
            matching: [
                "url",
                "download_url",
                "downloadUrl",
                "redirect_url",
                "redirectUrl",
                "direct_download_url",
                "directDownloadUrl",
                "stream_url",
                "streamUrl",
                "media_url",
                "mediaUrl",
                "link"
            ]
        ), let url = URL(string: value) {
            return url
        }
        return nil
    }

    private func saveDownloadedData(_ data: Data, suggestedName: String, fileExtension: String) throws -> URL {
        let base = DownloadSupport.tidyFilename(suggestedName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCache", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var url = directory.appendingPathComponent("\(base).\(fileExtension)")
            var suffix = 1
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(base)-\(suffix).\(fileExtension)")
                suffix += 1
            }

            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw DownloadError.fileSaveFailed(error.localizedDescription)
        }
    }

    private func persistDownloadedSongIfNeeded(_ song: SongMetadata) -> SongMetadata {
        guard UserDefaults.standard.bool(forKey: "keepDownloadedSongs") else {
            return song
        }

        let directory = SongMetadata.persistentDownloadsDirectory()
        let needsSecurityScope = directory.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log("Failed to create persistent download folder: \(error.localizedDescription)")
            return song
        }

        let ext = song.localURL.pathExtension.isEmpty ? "flac" : song.localURL.pathExtension
        let baseName = DownloadSupport.tidyFilename("\(song.artist) - \(song.title)")
        var destination = directory.appendingPathComponent("\(baseName).\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) && destination.path != song.localURL.path {
            destination = directory.appendingPathComponent("\(baseName)-\(suffix).\(ext)")
            suffix += 1
        }

        if destination.path == song.localURL.path {
            return song
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: song.localURL, to: destination)
            var updatedSong = song
            updatedSong.localURL = destination
            return updatedSong
        } catch {
            log("Failed to persist downloaded song \(song.title): \(error.localizedDescription)")
            return song
        }
    }

    private func fetchMappedURL(for seedURL: String, platform: DownloadPlatform) async throws -> String {
        guard let url = URL(string: "https://api.song.link/v1-alpha.1/links?url=\(seedURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else {
            throw DownloadError.invalidURL(seedURL)
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        try validateHTTP(response: response, data: data)

        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let links = obj["linksByPlatform"] as? [String: Any],
            let entry = links[platform.rawValue] as? [String: Any],
            let mapped = entry["url"] as? String,
            !mapped.isEmpty
        else {
            throw DownloadError.mappingFailed("Song.link could not map URL to \(platform.displayName).")
        }
        return mapped
    }

    private func buildTidalSearchQueries(
        for track: DownloadTrack,
        appleSong: AppleMusicAPI.AppleMusicSong?,
        metadataFallback: DownloadMetadataFallbackMatch? = nil
    ) -> [String] {
        var orderedQueries: [String] = []
        var seenQueries = Set<String>()

        func appendQuery(_ rawValue: String?) {
            let trimmed = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let normalized = DownloadSupport.normalizedSearchValue(trimmed)
            guard !normalized.isEmpty, seenQueries.insert(normalized).inserted else { return }
            orderedQueries.append(trimmed)
        }

        let title = appleSong?.attributes.name ?? metadataFallback?.title ?? track.name
        let artist = appleSong?.attributes.artistName ?? metadataFallback?.artist ?? track.artistLine
        let album = appleSong?.attributes.albumName ?? metadataFallback?.album ?? track.albumName
        let strippedArtist = primaryArtistName(from: artist)
        let simplifiedTitle = simplifiedTrackTitle(title)

        appendQuery(appleSong?.attributes.isrc)
        appendQuery("\(title) \(artist)")
        appendQuery("\(title) \(strippedArtist)")
        appendQuery("\(simplifiedTitle) \(artist)")
        appendQuery("\(simplifiedTitle) \(strippedArtist)")

        if !album.isEmpty, DownloadSupport.normalizedSearchValue(album) != "unknown album" {
            appendQuery("\(title) \(artist) \(album)")
            appendQuery("\(title) \(strippedArtist) \(album)")
            appendQuery("\(artist) \(album) \(title)")
            appendQuery("\(simplifiedTitle) \(artist) \(album)")
        }

        appendQuery("\(artist) \(title)")
        appendQuery("\(strippedArtist) \(simplifiedTitle)")
        appendQuery(title)
        appendQuery(simplifiedTitle)

        return orderedQueries
    }

    private func primaryArtistName(from artistLine: String) -> String {
        let separatorsPattern = #"\s*(?:,|&| x | y | feat\.?|ft\.?|with)\s*"#
        let canonicalized = artistLine.replacingOccurrences(of: separatorsPattern, with: ",", options: .regularExpression)
        let primary = canonicalized
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (primary?.isEmpty == false) ? primary! : artistLine
    }

    private func simplifiedTrackTitle(_ title: String) -> String {
        let withoutBracketed = title.replacingOccurrences(
            of: #"\s*[\(\[].*?[\)\]]"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = withoutBracketed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    private func searchTidalCandidateTrackIDs(
        for track: DownloadTrack,
        query: String,
        excluding excludedTrackIDs: Set<String>
    ) async -> [String] {
        let searchHosts = await rotatedTidalSearchHosts()

        var mergedCandidates: [TidalSearchItem] = []
        var seenCandidateIDs = Set<Int>()
        var sawResolvableFailure = false

        for host in searchHosts {
            do {
                let response = try await fetchTidalSearchResponse(query: query, host: host)
                let freshCandidates = response.data.items.filter { seenCandidateIDs.insert($0.id).inserted }
                mergedCandidates.append(contentsOf: freshCandidates)
                if !freshCandidates.isEmpty {
                    log("Tidal search host \(host) returned \(freshCandidates.count) candidate(s) for '\(query)'")
                }
            } catch {
                sawResolvableFailure = sawResolvableFailure || isTransientSearchFailure(error)
                log("Tidal search host \(host) failed for '\(query)': \(error.localizedDescription)")
            }
        }

        let rankedCandidates = mergedCandidates
            .filter { !excludedTrackIDs.contains(String($0.id)) }
            .map { candidate in
                (candidate, scoreTidalCandidate(candidate, for: track))
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.id < $1.0.id
                }
                return $0.1 > $1.1
            }

        let bestIDs = rankedCandidates.prefix(5).map { String($0.0.id) }
        if !bestIDs.isEmpty {
            log("Tidal search '\(query)' candidates: \(bestIDs.joined(separator: ", "))")
        } else if sawResolvableFailure {
            log("Tidal search '\(query)' had only transient host failures across all search backends.")
        }
        return bestIDs
    }

    private func searchQobuzCandidateTrackIDs(
        for track: DownloadTrack,
        query: String,
        excluding excludedTrackIDs: Set<String>
    ) async -> QobuzSearchOutcome {
        let searchBaseURLs = QobuzAPIRegistry.searchBaseURLs

        var mergedCandidates: [QobuzSearchTrackItem] = []
        var seenCandidateIDs = Set<String>()
        var sawResolvableFailure = false

        for baseURL in searchBaseURLs {
            do {
                let response = try await fetchQobuzSearchResponse(query: query, baseURL: baseURL)
                let freshCandidates = response.tracks.items.filter {
                    let id = String($0.id)
                    return seenCandidateIDs.insert(id).inserted
                }
                mergedCandidates.append(contentsOf: freshCandidates)
                if !freshCandidates.isEmpty {
                    log("Qobuz search host \(baseURL) returned \(freshCandidates.count) candidate(s) for '\(query)'")
                }
            } catch {
                sawResolvableFailure = sawResolvableFailure || isTransientSearchFailure(error)
                log("Qobuz search host \(baseURL) failed for '\(query)': \(error.localizedDescription)")
            }
        }

        let rankedCandidates = mergedCandidates
            .filter { !excludedTrackIDs.contains(String($0.id)) }
            .map { candidate in
                (candidate, scoreQobuzCandidate(candidate, for: track))
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.id < $1.0.id
                }
                return $0.1 > $1.1
            }

        let bestScore = rankedCandidates.first?.1 ?? 0
        let bestIDs = rankedCandidates.prefix(5).map { String($0.0.id) }
        if !bestIDs.isEmpty {
            log("Qobuz search '\(query)' candidates: \(bestIDs.joined(separator: ", "))")
        } else if sawResolvableFailure {
            log("Qobuz search '\(query)' had only transient host failures across all search backends.")
        }
        return QobuzSearchOutcome(trackIDs: bestIDs, bestScore: bestScore)
    }

    private func fetchPreferredTidalSearchResponse(
        query: String,
        limit: Int = 25,
        offset: Int = 0,
        logLabel: String
    ) async -> TidalSearchResponse? {
        let searchHosts = await rotatedTidalSearchHosts()

        var sawResolvableFailure = false

        for host in searchHosts {
            do {
                let response = try await fetchTidalSearchResponse(query: query, host: host, limit: limit, offset: offset)
                activeTidalSearchHost = host
                if !response.data.items.isEmpty {
                    log("Tidal \(logLabel) host \(host) returned \(response.data.items.count) candidate(s) for '\(query)'")
                }
                return response
            } catch {
                sawResolvableFailure = sawResolvableFailure || isTransientSearchFailure(error)
                log("Tidal \(logLabel) host \(host) failed for '\(query)': \(error.localizedDescription)")
            }
        }

        if sawResolvableFailure {
            errorText = "Tidal search backends are temporarily unavailable."
        }
        return nil
    }

    private func fetchTidalSearchResponse(query: String, host: String, limit: Int = 25, offset: Int = 0) async throws -> TidalSearchResponse {
        var lastError: Error?

        for attempt in 1...2 {
            do {
                var components = URLComponents(string: host)!
                components.queryItems = [
                    URLQueryItem(name: "s", value: query),
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset))
                ]

                guard let url = components.url else {
                    throw DownloadError.invalidURL(host)
                }

                let (data, response) = try await session.data(for: URLRequest(url: url))
                try validateHTTP(response: response, data: data)
                return try JSONDecoder().decode(TidalSearchResponse.self, from: data)
            } catch {
                lastError = error
                guard attempt < 2, isTransientSearchFailure(error) else { throw error }
                log("Retrying Tidal search host \(host) for '\(query)' after transient failure.")
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        throw lastError ?? DownloadError.searchFailed
    }

    private func fetchQobuzSearchResponse(query: String, baseURL: String) async throws -> QobuzSearchResponse {
        guard var components = URLComponents(string: "\(baseURL)/track/search") else {
            throw DownloadError.invalidURL(baseURL)
        }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else {
            throw DownloadError.invalidURL(baseURL)
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        try validateHTTP(response: response, data: data)
        return try JSONDecoder().decode(QobuzSearchResponse.self, from: data)
    }

    private func isTransientSearchFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private func scoreTidalCandidate(_ candidate: TidalSearchItem, for track: DownloadTrack) -> Int {
        let normalizedTrackTitle = DownloadSupport.normalizedSearchValue(track.name)
        let normalizedAlbumName = DownloadSupport.normalizedSearchValue(track.albumName)
        let candidateTitle = DownloadSupport.normalizedSearchValue(candidate.title)
        let candidateCombinedTitle = DownloadSupport.normalizedSearchValue(
            [candidate.title, candidate.version].compactMap { $0 }.joined(separator: " ")
        )

        var score = 0

        if !normalizedTrackTitle.isEmpty {
            if candidateCombinedTitle == normalizedTrackTitle {
                score += 180
            } else if candidateTitle == normalizedTrackTitle {
                score += 150
            } else if candidateCombinedTitle.contains(normalizedTrackTitle) || normalizedTrackTitle.contains(candidateCombinedTitle) {
                score += 110
            } else if candidateTitle.contains(normalizedTrackTitle) || normalizedTrackTitle.contains(candidateTitle) {
                score += 80
            }
        }

        let sourceArtistTokens = DownloadSupport.artistTokens(from: track.artistLine)
        let candidateArtists = (candidate.artists?.map(\.name) ?? [candidate.artist?.name].compactMap { $0 })
            .map(DownloadSupport.normalizedSearchValue)
        for token in sourceArtistTokens {
            if candidateArtists.contains(token) {
                score += 45
            } else if candidateArtists.contains(where: { $0.contains(token) || token.contains($0) }) {
                score += 25
            }
        }

        let candidateAlbumName = DownloadSupport.normalizedSearchValue(candidate.album?.title ?? "")
        if !normalizedAlbumName.isEmpty, normalizedAlbumName != "unknown album" {
            if candidateAlbumName == normalizedAlbumName {
                score += 35
            } else if candidateAlbumName.contains(normalizedAlbumName) || normalizedAlbumName.contains(candidateAlbumName) {
                score += 20
            }
        }

        if DownloadSupport.normalizedSearchValue(track.name).contains("remix"),
           DownloadSupport.normalizedSearchValue(candidate.version ?? "").contains("remix") {
            score += 20
        }

        if candidate.audioQuality?.uppercased().contains("LOSSLESS") == true {
            score += 5
        }

        return score
    }

    private func scoreQobuzCandidate(_ candidate: QobuzSearchTrackItem, for track: DownloadTrack) -> Int {
        let normalizedTrackTitle = DownloadSupport.normalizedSearchValue(track.name)
        let normalizedAlbumName = DownloadSupport.normalizedSearchValue(track.albumName)
        let candidateTitle = DownloadSupport.normalizedSearchValue(candidate.title)
        let candidateCombinedTitle = DownloadSupport.normalizedSearchValue(
            [candidate.title, candidate.version].compactMap { $0 }.joined(separator: " ")
        )

        var score = 0

        if !normalizedTrackTitle.isEmpty {
            if candidateCombinedTitle == normalizedTrackTitle {
                score += 180
            } else if candidateTitle == normalizedTrackTitle {
                score += 150
            } else if candidateCombinedTitle.contains(normalizedTrackTitle) || normalizedTrackTitle.contains(candidateCombinedTitle) {
                score += 110
            } else if candidateTitle.contains(normalizedTrackTitle) || normalizedTrackTitle.contains(candidateTitle) {
                score += 80
            }
        }

        let sourceArtistTokens = DownloadSupport.artistTokens(from: track.artistLine)
        let candidateArtists = DownloadSupport.artistTokens(from: candidate.performer?.name ?? candidate.album.artist.name)
        for token in sourceArtistTokens {
            if candidateArtists.contains(token) {
                score += 45
            } else if candidateArtists.contains(where: { $0.contains(token) || token.contains($0) }) {
                score += 25
            }
        }

        let candidateAlbumName = DownloadSupport.normalizedSearchValue(candidate.album.title)
        if !normalizedAlbumName.isEmpty, normalizedAlbumName != "unknown album" {
            if candidateAlbumName == normalizedAlbumName {
                score += 35
            } else if candidateAlbumName.contains(normalizedAlbumName) || normalizedAlbumName.contains(candidateAlbumName) {
                score += 20
            }
        }

        if candidate.downloadable == true {
            score += 8
        }

        return score
    }

    private func scoreDisplayTidalCandidate(_ candidate: TidalSearchItem, query: String) -> Int {
        let normalizedQuery = DownloadSupport.normalizedSearchValue(query)
        let title = DownloadSupport.normalizedSearchValue(candidate.title)
        let combinedTitle = DownloadSupport.normalizedSearchValue(displayTitle(for: candidate))
        let artistLine = DownloadSupport.normalizedSearchValue(tidalArtistLine(for: candidate))
        let albumTitle = DownloadSupport.normalizedSearchValue(candidate.album?.title ?? "")

        var score = 0

        if combinedTitle == normalizedQuery {
            score += 180
        } else if title == normalizedQuery {
            score += 160
        } else if combinedTitle.contains(normalizedQuery) || normalizedQuery.contains(combinedTitle) {
            score += 120
        } else if title.contains(normalizedQuery) || normalizedQuery.contains(title) {
            score += 95
        }

        for token in normalizedQuery.split(separator: " ").map(String.init) where token.count > 1 {
            if artistLine.contains(token) {
                score += 20
            }
            if albumTitle.contains(token) {
                score += 8
            }
        }

        if candidate.audioQuality?.uppercased().contains("LOSSLESS") == true {
            score += 5
        }

        return score
    }

    private func displayTitle(for candidate: TidalSearchItem) -> String {
        guard let version = candidate.version?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            return candidate.title
        }

        let normalizedTitle = DownloadSupport.normalizedSearchValue(candidate.title)
        let normalizedVersion = DownloadSupport.normalizedSearchValue(version)
        guard !normalizedVersion.isEmpty, !normalizedTitle.contains(normalizedVersion) else {
            return candidate.title
        }

        return "\(candidate.title) (\(version))"
    }

    private func tidalArtistLine(for candidate: TidalSearchItem) -> String {
        let artists = candidate.artists?.map(\.name) ?? [candidate.artist?.name].compactMap { $0 }
        let filtered = artists.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if filtered.isEmpty {
            return "Unknown Artist"
        }
        return filtered.joined(separator: ", ")
    }

    private func mappingSeedURL(for sourceURL: String) -> String {
        sourceURL
    }

    private func tidalImageURL(for identifier: String?, size: Int = 320) -> URL? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let path = identifier.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(path)/\(size)x\(size).jpg")
    }

    private func fetchDataWithProgress(
        for request: URLRequest,
        onProgress: @escaping (Double, Double) -> Void
    ) async throws -> (Data, URLResponse) {
        let downloader = ProgressiveDataFetcher()
        return try await downloader.fetch(request: request) { progress, speedBps in
            Task { @MainActor in
                onProgress(progress, speedBps)
            }
        }
    }

    private func makeRequest(label: String, urlString: String, tidalAPIBaseURL: String? = nil) -> BackendCandidate? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyZarzHeaders(to: &request)
        return BackendCandidate(label: label, request: request, tidalAPIBaseURL: tidalAPIBaseURL, customDownload: nil)
    }

    private func makePOSTRequest(label: String, urlString: String, jsonBody: Data, tidalAPIBaseURL: String? = nil) -> BackendCandidate? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyZarzHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonBody
        return BackendCandidate(label: label, request: request, tidalAPIBaseURL: tidalAPIBaseURL, customDownload: nil)
    }

    private func applyZarzHeaders(to request: inout URLRequest) {
        guard request.url?.host?.contains("zarz.moe") == true else { return }
        request.setValue("SpotiFLAC-Mobile/4.5.5", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    }

    private func searchAlbums(query: String, limit: Int, offset: Int = 0) async -> [AppleMusicAlbumResult] {
        let fallback = await AppleMusicAPI.shared.searchAlbumsPublic(query: query, limit: limit, offset: offset)
        if !fallback.isEmpty {
            log("Album search is using Apple Music public search page.")
        }
        return fallback.map {
            AppleMusicAlbumResult(
                id: $0.id,
                attributes: AppleMusicAlbumResultAttributes(
                    name: $0.name,
                    artistName: $0.artistName,
                    artwork: $0.artwork
                )
            )
        }
    }

    private func searchPlaylists(query: String, limit: Int, offset: Int = 0) async -> [AppleMusicPlaylistResult] {
        let fallback = await AppleMusicAPI.shared.searchPlaylistsPublic(query: query, limit: limit, offset: offset)
        if !fallback.isEmpty {
            log("Playlist search is using Apple Music public search page.")
        }
        return fallback.map {
            AppleMusicPlaylistResult(
                id: $0.id,
                attributes: AppleMusicPlaylistAttributes(
                    name: $0.name,
                    curatorName: $0.curatorName,
                    artwork: $0.artwork
                ),
                relationships: nil
            )
        }
    }

    private func searchTidalTracks(query: String, limit: Int = 25, offset: Int = 0) async -> [DownloadTrack] {
        guard let response = await fetchPreferredTidalSearchResponse(query: query, limit: limit, offset: offset, logLabel: "search display") else {
            return []
        }

        let rankedCandidates = response.data.items
            .map { candidate in
                (candidate, scoreDisplayTidalCandidate(candidate, query: query))
            }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.id < $1.0.id
                }
                return $0.1 > $1.1
            }
            .map(\.0)

        return mapTidalSearchItemsToTracks(rankedCandidates)
    }

    private func buildTidalArtists(from items: [TidalSearchItem], query: String) -> [DownloadArtist] {
        let normalizedQuery = DownloadSupport.normalizedSearchValue(query)
        var bestArtistsByKey: [String: (artist: DownloadArtist, score: Int)] = [:]

        for candidate in items {
            let artists = candidate.artists ?? [candidate.artist].compactMap { $0 }
            for artist in artists {
                let normalizedName = DownloadSupport.normalizedSearchValue(artist.name)
                guard !normalizedName.isEmpty else { continue }

                let score: Int
                if normalizedName == normalizedQuery {
                    score = 220
                } else if normalizedName.contains(normalizedQuery) || normalizedQuery.contains(normalizedName) {
                    score = 150
                } else if normalizedQuery.split(separator: " ").allSatisfy({ token in
                    normalizedName.contains(String(token))
                }) {
                    score = 110
                } else {
                    continue
                }

                let artistID = artist.id.map(String.init) ?? "tidal:\(normalizedName)"
                let entry = DownloadArtist(
                    id: artistID,
                    name: artist.name,
                    provider: .tidal,
                    artworkURL: tidalImageURL(for: artist.picture)
                )

                if let existing = bestArtistsByKey[artistID], existing.score >= score {
                    continue
                }
                bestArtistsByKey[artistID] = (entry, score)
            }
        }

        return bestArtistsByKey.values
            .sorted {
                if $0.score == $1.score {
                    return $0.artist.name.localizedCaseInsensitiveCompare($1.artist.name) == .orderedAscending
                }
                return $0.score > $1.score
            }
            .prefix(8)
            .map(\.artist)
    }

    private func mapTidalSearchItemsToTracks(_ items: [TidalSearchItem]) -> [DownloadTrack] {
        items.map { item in
            DownloadTrack(
                id: String(item.id),
                name: displayTitle(for: item),
                artistLine: tidalArtistLine(for: item),
                albumName: item.album?.title ?? "Unknown Album",
                artworkURL: tidalImageURL(for: item.album?.cover),
                isExplicit: item.explicit ?? false,
                sourceURL: item.url ?? "https://tidal.com/browse/track/\(item.id)",
                sourceContext: .song,
                provider: .tidal,
                artistIdentifier: item.artists?.first?.id.map(String.init) ?? item.artist?.id.map(String.init),
                albumIdentifier: item.album?.id.map(String.init),
                previewURL: nil
            )
        }
    }

    private func mapTidalSearchItemsToAlbums(_ items: [TidalSearchItem]) -> [DownloadAlbum] {
        items.compactMap { item in
            guard let album = item.album else { return nil }
            return DownloadAlbum(
                id: album.id.map(String.init) ?? "\(DownloadSupport.normalizedSearchValue(tidalArtistLine(for: item)))-\(DownloadSupport.normalizedSearchValue(album.title))",
                name: album.title,
                artistLine: tidalArtistLine(for: item),
                artworkURL: tidalImageURL(for: album.cover),
                sourceURL: item.url ?? "https://tidal.com/browse/album/\(album.id ?? 0)",
                provider: .tidal,
                artistIdentifier: item.artists?.first?.id.map(String.init) ?? item.artist?.id.map(String.init),
                albumIdentifier: album.id.map(String.init)
            )
        }
    }

    private func metadataTrack(from song: iTunesSong) -> DownloadTrack? {
        guard
            let trackID = song.trackId,
            let title = song.trackName,
            let artist = song.artistName
        else { return nil }

        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        let albumID = song.collectionId.map { "itunes-album-\($0)" } ?? "itunes-album-\(DownloadSupport.normalizedSearchValue(artist))-\(DownloadSupport.normalizedSearchValue(song.collectionName ?? "Unknown Album"))"
        let artworkURL = song.artworkUrl100?
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")

        return DownloadTrack(
            id: "itunes-\(trackID)",
            name: title,
            artistLine: artist,
            albumName: song.collectionName ?? "Unknown Album",
            artworkURL: artworkURL.flatMap(URL.init(string:)),
            isExplicit: false,
            sourceURL: song.trackViewUrl ?? "https://music.apple.com/\(region)/song/\(trackID)",
            sourceContext: .song,
            provider: .metadata,
            artistIdentifier: song.artistId.map { "itunes-artist-\($0)" },
            albumIdentifier: albumID,
            previewURL: song.previewUrl.flatMap(URL.init(string:))
        )
    }

    private func metadataTrack(from song: DeezerSong) -> DownloadTrack {
        let normalizedArtist = DownloadSupport.normalizedSearchValue(song.artist.name)
        let normalizedAlbum = DownloadSupport.normalizedSearchValue(song.album.title)
        return DownloadTrack(
            id: "deezer-\(song.id)",
            name: song.title,
            artistLine: song.artist.name,
            albumName: song.album.title,
            artworkURL: URL(string: song.album.cover_xl),
            isExplicit: song.explicit_lyrics ?? false,
            sourceURL: song.link ?? "https://www.deezer.com/track/\(song.id)",
            sourceContext: .song,
            provider: .metadata,
            artistIdentifier: "deezer-artist-\(normalizedArtist)",
            albumIdentifier: "deezer-album-\(normalizedArtist)-\(normalizedAlbum)",
            previewURL: song.preview.flatMap(URL.init(string:))
        )
    }

    private func buildMetadataAlbums(from tracks: [DownloadTrack]) -> [DownloadAlbum] {
        var grouped: [String: [DownloadTrack]] = [:]
        var orderedKeys: [String] = []

        for track in tracks {
            let key = track.albumIdentifier ?? "metadata-album-\(DownloadSupport.normalizedSearchValue(track.artistLine))-\(DownloadSupport.normalizedSearchValue(track.albumName))"
            if grouped[key] == nil {
                grouped[key] = []
                orderedKeys.append(key)
            }
            grouped[key]?.append(track)
        }

        metadataAlbumTrackCache = grouped

        return orderedKeys.compactMap { key in
            guard let firstTrack = grouped[key]?.first else { return nil }
            return DownloadAlbum(
                id: key,
                name: firstTrack.albumName,
                artistLine: firstTrack.artistLine,
                artworkURL: firstTrack.artworkURL,
                sourceURL: firstTrack.sourceURL,
                provider: .metadata,
                artistIdentifier: firstTrack.artistIdentifier,
                albumIdentifier: key
            )
        }
    }

    private func fetchAlbumTracks(albumID: String, fallbackAlbumName: String, sourceURL: String? = nil) async -> [DownloadTrack] {
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"

        let publicTracks = await AppleMusicAPI.shared.fetchAlbumTracksPublic(id: albumID, urlHint: sourceURL)
        return publicTracks.map { item in
            let songURL = item.attributes.url ?? "https://music.apple.com/\(region)/song/\(item.id)"
            return DownloadTrack(
                id: item.id,
                name: item.attributes.name,
                artistLine: item.attributes.artistName,
                albumName: item.attributes.albumName ?? fallbackAlbumName,
                artworkURL: item.attributes.artwork?.artworkURL(width: 400, height: 400),
                isExplicit: item.attributes.contentRating == "explicit",
                sourceURL: songURL,
                sourceContext: .album,
                provider: .appleMusic,
                artistIdentifier: item.relationships?.artists?.data.first?.id,
                albumIdentifier: item.relationships?.albums?.data.first?.id ?? albumID,
                previewURL: nil
            )
        }
    }

    private func fetchTidalAlbumTracks(for album: DownloadAlbum) async -> [DownloadTrack] {
        if let albumIDString = album.albumIdentifier ?? Int(album.id).map(String.init),
           let albumID = Int(albumIDString),
           let exactTracks = await fetchTidalAlbumTracks(albumID: albumID, fallbackAlbum: album),
           !exactTracks.isEmpty {
            return exactTracks
        }

        let query = "\(album.artistLine) \(album.name)"
        let tracks = await searchTidalTracks(query: query, limit: 75)
        if let albumIdentifier = album.albumIdentifier {
            let exactAlbumID = tracks.filter { $0.albumIdentifier == albumIdentifier }
            if !exactAlbumID.isEmpty {
                return exactAlbumID
            }
        }

        let exactAlbum = tracks.filter { track in
            matchesArtistLine(track.artistLine, artistName: album.artistLine) &&
            DownloadSupport.normalizedSearchValue(track.albumName) == DownloadSupport.normalizedSearchValue(album.name)
        }

        if !exactAlbum.isEmpty {
            return exactAlbum
        }

        return tracks.filter {
            DownloadSupport.normalizedSearchValue($0.albumName) == DownloadSupport.normalizedSearchValue(album.name)
        }
    }

    private func fetchTidalAlbumTracks(albumID: Int, fallbackAlbum: DownloadAlbum) async -> [DownloadTrack]? {
        guard let host = await preferredTidalBaseURL() else { return nil }
        guard var components = URLComponents(string: "\(host)/album/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(albumID)),
            URLQueryItem(name: "limit", value: "500")
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            try validateHTTP(response: response, data: data)
            let decoded = try JSONDecoder().decode(TidalAlbumResponse.self, from: data)
            let albumData = decoded.data
            return albumData.items.map { wrapper in
                let item = wrapper.item
                return DownloadTrack(
                    id: String(item.id),
                    name: displayTitle(for: item),
                    artistLine: tidalArtistLine(for: item),
                    albumName: albumData.title,
                    artworkURL: tidalImageURL(for: albumData.cover),
                    isExplicit: item.explicit ?? albumData.explicit ?? false,
                    sourceURL: item.url ?? "https://tidal.com/browse/track/\(item.id)",
                    sourceContext: .album,
                    provider: .tidal,
                    artistIdentifier: item.artists?.first?.id.map(String.init) ?? item.artist?.id.map(String.init),
                    albumIdentifier: String(albumData.id),
                    previewURL: nil
                )
            }
        } catch {
            log("Tidal album fetch failed for \(albumID): \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchTidalArtistAlbums(artistID: Int) async -> [DownloadAlbum] {
        let hosts = await tidalBaseURLCandidates()
        guard !hosts.isEmpty else { return [] }

        for host in hosts {
            guard var components = URLComponents(string: "\(host)/artist/") else { continue }
            components.queryItems = [
                URLQueryItem(name: "f", value: String(artistID)),
                URLQueryItem(name: "skip_tracks", value: "true")
            ]
            guard let url = components.url else { continue }

            do {
                let (data, response) = try await session.data(for: URLRequest(url: url))
                try validateHTTP(response: response, data: data)
                let decoded = try JSONDecoder().decode(TidalArtistAlbumsResponse.self, from: data)
                return decoded.albums.items.map { album in
                    DownloadAlbum(
                        id: String(album.id),
                        name: album.title,
                        artistLine: album.artist?.name ?? decoded.artist?.name ?? "Unknown Artist",
                        artworkURL: tidalImageURL(for: album.cover),
                        sourceURL: album.url ?? "https://tidal.com/browse/album/\(album.id)",
                        provider: .tidal,
                        artistIdentifier: String(artistID),
                        albumIdentifier: String(album.id)
                    )
                }
            } catch {
                log("Tidal artist albums fetch failed for \(artistID) via \(host): \(error.localizedDescription)")
            }
        }

        return []
    }

    private func fetchTidalArtist(id: String, sourceURL: String? = nil) async -> DownloadArtist? {
        guard let artistID = Int(id) else { return nil }
        let hosts = await tidalBaseURLCandidates()

        for host in hosts {
            guard var components = URLComponents(string: "\(host)/artist/") else { continue }
            components.queryItems = [
                URLQueryItem(name: "f", value: String(artistID)),
                URLQueryItem(name: "skip_tracks", value: "true")
            ]
            guard let url = components.url else { continue }

            do {
                let (data, response) = try await session.data(for: URLRequest(url: url))
                try validateHTTP(response: response, data: data)
                let decoded = try JSONDecoder().decode(TidalArtistAlbumsResponse.self, from: data)
                guard let artist = decoded.artist else { continue }
                return DownloadArtist(
                    id: String(artist.id),
                    name: artist.name,
                    provider: .tidal,
                    artworkURL: tidalImageURL(for: artist.picture)
                )
            } catch {
                log("Tidal artist fetch failed for \(artistID) via \(host): \(error.localizedDescription)")
            }
        }

        if let sourceURL,
           let fallbackArtist = await fetchTidalArtistFromPublicPage(sourceURL: sourceURL, fallbackID: id) {
            return fallbackArtist
        }

        return nil
    }

    private func fetchTidalArtistFromPublicPage(sourceURL: String, fallbackID: String) async -> DownloadArtist? {
        guard let url = URL(string: sourceURL) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response: response, data: data)
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }

            let rawTitle =
                extractHTMLMetaContent(property: "og:title", in: html) ??
                extractHTMLMetaContent(name: "twitter:title", in: html) ??
                extractHTMLTagContent(tag: "title", in: html)

            let artwork =
                extractHTMLMetaContent(property: "og:image", in: html) ??
                extractHTMLMetaContent(name: "twitter:image", in: html)

            let cleanedTitle = rawTitle?
                .replacingOccurrences(of: "| TIDAL", with: "")
                .replacingOccurrences(of: " on TIDAL", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let name = cleanedTitle, !name.isEmpty else { return nil }

            return DownloadArtist(
                id: fallbackID,
                name: name,
                provider: .tidal,
                artworkURL: artwork.flatMap(URL.init(string:))
            )
        } catch {
            log("Tidal public page artist fallback failed for \(sourceURL): \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchTidalTrackFromPublicPage(sourceURL: String, fallbackID: String) async -> DownloadTrack? {
        guard let url = URL(string: sourceURL) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response: response, data: data)
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }

            let rawTitle =
                extractHTMLMetaContent(property: "og:title", in: html) ??
                extractHTMLMetaContent(name: "twitter:title", in: html) ??
                extractHTMLTagContent(tag: "title", in: html)

            let rawDescription =
                extractHTMLMetaContent(property: "og:description", in: html) ??
                extractHTMLMetaContent(name: "description", in: html) ??
                extractHTMLMetaContent(name: "twitter:description", in: html)

            let artwork =
                extractHTMLMetaContent(property: "og:image", in: html) ??
                extractHTMLMetaContent(name: "twitter:image", in: html)

            let parsed = parseTidalTrackMetadata(title: rawTitle, description: rawDescription)
            guard let title = parsed.title, !title.isEmpty else { return nil }

            return DownloadTrack(
                id: fallbackID,
                name: title,
                artistLine: parsed.artist ?? "Unknown Artist",
                albumName: parsed.album ?? "Unknown Album",
                artworkURL: artwork.flatMap(URL.init(string:)),
                isExplicit: false,
                sourceURL: sourceURL,
                sourceContext: .song,
                provider: .tidal,
                artistIdentifier: nil,
                albumIdentifier: nil,
                previewURL: nil
            )
        } catch {
            log("Tidal public page track fallback failed for \(sourceURL): \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSpotifyToken() async -> String? {
        guard let url = URL(string: "https://open.spotify.com/get_access_token?reason=transport&productType=web_player") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["accessToken"] as? String {
                return token
            }
        } catch {
            log("Failed to fetch Spotify token: \(error.localizedDescription)")
        }
        return nil
    }

    private func fetchSpotifyTrack(id: String, sourceURL: String) async -> DownloadTrack? {
        if let token = await fetchSpotifyToken() {
            guard let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)") else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    
                    let name = json["name"] as? String ?? "Unknown Title"
                    let artists = json["artists"] as? [[String: Any]] ?? []
                    let artistLine = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                    let album = json["album"] as? [String: Any]
                    let albumName = album?["name"] as? String ?? "Unknown Album"
                    let artworkURLString = (album?["images"] as? [[String: Any]])?.first?["url"] as? String
                    let artworkURL = artworkURLString.flatMap(URL.init(string:))
                    let explicit = json["explicit"] as? Bool ?? false
                    let previewURLString = json["preview_url"] as? String
                    let previewURL = previewURLString.flatMap(URL.init(string:))
                    
                    return DownloadTrack(
                        id: id,
                        name: name,
                        artistLine: artistLine.isEmpty ? "Unknown Artist" : artistLine,
                        albumName: albumName,
                        artworkURL: artworkURL,
                        isExplicit: explicit,
                        sourceURL: sourceURL,
                        sourceContext: .song,
                        provider: .metadata,
                        artistIdentifier: nil,
                        albumIdentifier: album?["id"] as? String,
                        previewURL: previewURL
                    )
                }
            } catch {
                log("Spotify API track fetch failed: \(error.localizedDescription)")
            }
        }
        return await fetchSpotifyTrackFromPublicPage(sourceURL: sourceURL, fallbackID: id)
    }

    private func extractSpotifyJSONLD(in html: String) -> [String: Any]? {
        let pattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let jsonString = firstRegexCapture(in: html, pattern: pattern, group: 1) else {
            return nil
        }
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func fetchSpotifyTrackFromPublicPage(sourceURL: String, fallbackID: String) async -> DownloadTrack? {
        guard let url = URL(string: sourceURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response: response, data: data)
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }
            
            var title = "Unknown Title"
            var artist = "Unknown Artist"
            var albumName = "Unknown Album"
            var artworkURL: URL?
            
            if let jsonld = extractSpotifyJSONLD(in: html) {
                if let name = jsonld["name"] as? String {
                    title = name
                }
                if let artists = jsonld["byArtist"] as? [[String: Any]] {
                    artist = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                } else if let artistObj = jsonld["byArtist"] as? [String: Any] {
                    artist = artistObj["name"] as? String ?? "Unknown Artist"
                }
                if let albumObj = jsonld["inAlbum"] as? [String: Any],
                   let aName = albumObj["name"] as? String {
                    albumName = aName
                }
                if let img = jsonld["image"] as? String {
                    artworkURL = URL(string: img)
                }
            }
            
            if title == "Unknown Title" || artist == "Unknown Artist" || albumName == "Unknown Album" {
                let ogTitle = extractHTMLMetaContent(property: "og:title", in: html) ??
                              extractHTMLMetaContent(name: "twitter:title", in: html) ??
                              extractHTMLTagContent(tag: "title", in: html)
                
                let ogDescription = extractHTMLMetaContent(property: "og:description", in: html) ??
                                    extractHTMLMetaContent(name: "description", in: html)
                
                let artwork = extractHTMLMetaContent(property: "og:image", in: html)
                
                if title == "Unknown Title", let ogTitleClean = ogTitle {
                    if let range = ogTitleClean.range(of: " - song", options: .caseInsensitive) {
                        title = String(ogTitleClean[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let range = ogTitleClean.range(of: " - album", options: .caseInsensitive) {
                        title = String(ogTitleClean[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if ogTitleClean.contains("| Spotify") {
                        title = ogTitleClean.replacingOccurrences(of: "| Spotify", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        title = ogTitleClean
                    }
                }
                
                if let desc = ogDescription {
                    let parts = desc.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if artist == "Unknown Artist", parts.count >= 1 {
                        var rawArtist = parts[0]
                        if rawArtist.hasPrefix("Listen to ") {
                            rawArtist = rawArtist.replacingOccurrences(of: #"Listen to .*? on Spotify\.\s*"#, with: "", options: .regularExpression)
                        }
                        if !rawArtist.isEmpty {
                            artist = rawArtist
                        }
                    }
                    if albumName == "Unknown Album", parts.count >= 3 {
                        let p1Lower = parts[1].lowercased()
                        if p1Lower != "song" && p1Lower != "single" {
                            let hasSongIndicator = parts.contains { $0.lowercased() == "song" || $0.lowercased() == "single" }
                            if hasSongIndicator {
                                albumName = parts[1]
                            }
                        }
                    }
                }
                
                if artist == "Unknown Artist", let ogTitleClean = ogTitle {
                    if let byRange = ogTitleClean.range(of: "by ", options: .backwards) {
                        let afterBy = ogTitleClean[byRange.upperBound...]
                        let cleanArtist = afterBy.replacingOccurrences(of: "| Spotify", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanArtist.isEmpty {
                            artist = cleanArtist
                        }
                    }
                }
                
                if artworkURL == nil {
                    artworkURL = artwork.flatMap(URL.init(string:))
                }
            }
            
            return DownloadTrack(
                id: fallbackID,
                name: title,
                artistLine: artist,
                albumName: albumName,
                artworkURL: artworkURL,
                isExplicit: false,
                sourceURL: sourceURL,
                sourceContext: .song,
                provider: .metadata,
                artistIdentifier: nil,
                albumIdentifier: nil,
                previewURL: nil
            )
        } catch {
            log("Spotify public page track fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSpotifyAlbum(id: String, sourceURL: String) async -> (DownloadAlbum, [DownloadTrack])? {
        if let token = await fetchSpotifyToken() {
            guard let url = URL(string: "https://api.spotify.com/v1/albums/\(id)") else { return nil }
            var albumRequest = URLRequest(url: url)
            albumRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (albumData, response) = try await session.data(for: albumRequest)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: albumData) as? [String: Any] {
                    
                    let albumName = json["name"] as? String ?? "Unknown Album"
                    let artists = json["artists"] as? [[String: Any]] ?? []
                    let artistLine = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                    let artworkURLString = (json["images"] as? [[String: Any]])?.first?["url"] as? String
                    let artworkURL = artworkURLString.flatMap(URL.init(string:))
                    
                    let albumResult = DownloadAlbum(
                        id: id,
                        name: albumName,
                        artistLine: artistLine.isEmpty ? "Unknown Artist" : artistLine,
                        artworkURL: artworkURL,
                        sourceURL: sourceURL,
                        provider: .metadata,
                        artistIdentifier: nil,
                        albumIdentifier: id
                    )
                    
                    var tracks: [DownloadTrack] = []
                    
                    if let tracksContainer = json["tracks"] as? [String: Any],
                       let items = tracksContainer["items"] as? [[String: Any]] {
                        for item in items {
                            if let trackID = item["id"] as? String {
                                let trackName = item["name"] as? String ?? "Unknown Title"
                                let trackArtists = item["artists"] as? [[String: Any]] ?? []
                                let trackArtistLine = trackArtists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                                let explicit = item["explicit"] as? Bool ?? false
                                let trackURL = "https://open.spotify.com/track/\(trackID)"
                                
                                tracks.append(DownloadTrack(
                                    id: trackID,
                                    name: trackName,
                                    artistLine: trackArtistLine.isEmpty ? artistLine : trackArtistLine,
                                    albumName: albumName,
                                    artworkURL: artworkURL,
                                    isExplicit: explicit,
                                    sourceURL: trackURL,
                                    sourceContext: .album,
                                    provider: .metadata,
                                    artistIdentifier: nil,
                                    albumIdentifier: id,
                                    previewURL: (item["preview_url"] as? String).flatMap(URL.init(string:))
                                ))
                            }
                        }
                    }
                    
                    return (albumResult, tracks)
                }
            } catch {
                log("Spotify API album fetch failed: \(error.localizedDescription)")
            }
        }
        return await fetchSpotifyAlbumFromPublicPage(sourceURL: sourceURL, fallbackID: id)
    }

    private func fetchSpotifyAlbumFromPublicPage(sourceURL: String, fallbackID: String) async -> (DownloadAlbum, [DownloadTrack])? {
        if let embedURL = URL(string: "https://open.spotify.com/embed/album/\(fallbackID)") {
            do {
                let (data, response) = try await session.data(from: embedURL)
                if let html = String(data: data, encoding: .utf8), !html.isEmpty,
                   let parsed = parseSpotifyEmbedHTML(in: html, fallbackID: fallbackID, sourceURL: sourceURL, sourceContext: .album) {
                    return parsed
                }
            } catch {
                log("Spotify public page album embed fetch failed: \(error.localizedDescription)")
            }
        }

        guard let url = URL(string: sourceURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response: response, data: data)
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }
            
            var albumName = "Unknown Album"
            var artistName = "Unknown Artist"
            var artworkURL: URL?
            
            if let jsonld = extractSpotifyJSONLD(in: html) {
                if let name = jsonld["name"] as? String {
                    albumName = name
                }
                if let artists = jsonld["byArtist"] as? [[String: Any]] {
                    artistName = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                } else if let artistObj = jsonld["byArtist"] as? [String: Any] {
                    artistName = artistObj["name"] as? String ?? "Unknown Artist"
                }
                if let img = jsonld["image"] as? String {
                    artworkURL = URL(string: img)
                }
            }
            
            if albumName == "Unknown Album" || artistName == "Unknown Artist" || artworkURL == nil {
                let ogTitle = extractHTMLMetaContent(property: "og:title", in: html) ??
                              extractHTMLMetaContent(name: "twitter:title", in: html) ??
                              extractHTMLTagContent(tag: "title", in: html)
                
                let ogDescription = extractHTMLMetaContent(property: "og:description", in: html) ??
                                    extractHTMLMetaContent(name: "description", in: html)
                
                let artwork = extractHTMLMetaContent(property: "og:image", in: html)
                
                if let ogTitleClean = ogTitle {
                    albumName = ogTitleClean.replacingOccurrences(of: "| Spotify", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if let range = albumName.range(of: " - album", options: .caseInsensitive) {
                        albumName = String(albumName[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                if let desc = ogDescription {
                    let parts = desc.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if parts.count >= 1 {
                        var rawArtist = parts[0]
                        if rawArtist.hasPrefix("Listen to ") {
                            rawArtist = rawArtist.replacingOccurrences(of: #"Listen to .*? on Spotify\.\s*"#, with: "", options: .regularExpression)
                        }
                        if !rawArtist.isEmpty {
                            artistName = rawArtist
                        }
                    }
                }
                
                if artworkURL == nil {
                    artworkURL = artwork.flatMap(URL.init(string:))
                }
            }
            
            let albumResult = DownloadAlbum(
                id: fallbackID,
                name: albumName,
                artistLine: artistName,
                artworkURL: artworkURL,
                sourceURL: sourceURL,
                provider: .metadata,
                artistIdentifier: nil,
                albumIdentifier: fallbackID
            )
            
            let tracks = extractSpotifyTracksFromHTML(in: html, fallbackArtist: artistName, fallbackAlbumName: albumName, artworkURL: artworkURL, sourceContext: .album)
            let finalTracks = tracks.isEmpty ? [
                DownloadTrack(
                    id: fallbackID,
                    name: albumName,
                    artistLine: artistName,
                    albumName: albumName,
                    artworkURL: artworkURL,
                    isExplicit: false,
                    sourceURL: sourceURL,
                    sourceContext: .album,
                    provider: .metadata,
                    artistIdentifier: nil,
                    albumIdentifier: fallbackID,
                    previewURL: nil
                )
            ] : tracks
            return (albumResult, finalTracks)
        } catch {
            log("Spotify public page album failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSpotifyPlaylistFromPublicPage(sourceURL: String, fallbackID: String) async -> (DownloadAlbum, [DownloadTrack])? {
        if let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(fallbackID)") {
            do {
                let (data, response) = try await session.data(from: embedURL)
                if let html = String(data: data, encoding: .utf8), !html.isEmpty,
                   let parsed = parseSpotifyEmbedHTML(in: html, fallbackID: fallbackID, sourceURL: sourceURL, sourceContext: .song) {
                    var enrichedAlbum = parsed.album
                    let creator = parsed.album.artistLine
                    let trackCount = parsed.tracks.count
                    let desc = "Playlist • \(creator) • \(trackCount) items"
                    enrichedAlbum = DownloadAlbum(
                        id: enrichedAlbum.id,
                        name: enrichedAlbum.name,
                        artistLine: desc,
                        artworkURL: enrichedAlbum.artworkURL,
                        sourceURL: enrichedAlbum.sourceURL,
                        provider: enrichedAlbum.provider,
                        artistIdentifier: enrichedAlbum.artistIdentifier,
                        albumIdentifier: enrichedAlbum.albumIdentifier
                    )
                    return (enrichedAlbum, parsed.tracks)
                }
            } catch {
                log("Spotify public page playlist embed fetch failed: \(error.localizedDescription)")
            }
        }

        guard let url = URL(string: sourceURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response: response, data: data)
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }
            
            var playlistName = "Unknown Playlist"
            var description = "Spotify Playlist"
            var artworkURL: URL?
            
            if let jsonld = extractSpotifyJSONLD(in: html) {
                if let name = jsonld["name"] as? String {
                    playlistName = name
                }
                if let desc = jsonld["description"] as? String {
                    description = desc
                }
                if let img = jsonld["image"] as? String {
                    artworkURL = URL(string: img)
                }
            }
            
            if playlistName == "Unknown Playlist" || artworkURL == nil {
                let ogTitle = extractHTMLMetaContent(property: "og:title", in: html) ??
                              extractHTMLMetaContent(name: "twitter:title", in: html) ??
                              extractHTMLTagContent(tag: "title", in: html)
                
                let ogDescription = extractHTMLMetaContent(property: "og:description", in: html) ??
                                    extractHTMLMetaContent(name: "description", in: html)
                
                let artwork = extractHTMLMetaContent(property: "og:image", in: html)
                
                if playlistName == "Unknown Playlist", let ogTitleClean = ogTitle {
                    playlistName = ogTitleClean.replacingOccurrences(of: "| Spotify", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if description == "Spotify Playlist", let desc = ogDescription {
                    description = desc
                }
                if artworkURL == nil {
                    artworkURL = artwork.flatMap(URL.init(string:))
                }
            }
            
            let playlistResult = DownloadAlbum(
                id: fallbackID,
                name: playlistName,
                artistLine: description,
                artworkURL: artworkURL,
                sourceURL: sourceURL,
                provider: .metadata,
                artistIdentifier: nil,
                albumIdentifier: fallbackID
            )
            
            let tracks = extractSpotifyTracksFromHTML(in: html, fallbackArtist: "Unknown Artist", fallbackAlbumName: playlistName, artworkURL: artworkURL, sourceContext: .song)
            return (playlistResult, tracks)
        } catch {
            log("Spotify public page playlist fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSpotifyArtistFromPublicPage(sourceURL: String, fallbackID: String) async -> DownloadArtist? {
        guard let url = URL(string: sourceURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            try validateHTTP(response: response, data: data)
            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }
            
            var artistName = "Unknown Artist"
            var artworkURL: URL?
            
            if let jsonld = extractSpotifyJSONLD(in: html) {
                if let name = jsonld["name"] as? String {
                    artistName = name
                }
                if let img = jsonld["image"] as? String {
                    artworkURL = URL(string: img)
                }
            }
            
            if artistName == "Unknown Artist" {
                let ogTitle = extractHTMLMetaContent(property: "og:title", in: html) ??
                              extractHTMLMetaContent(name: "twitter:title", in: html) ??
                              extractHTMLTagContent(tag: "title", in: html)
                
                let artwork = extractHTMLMetaContent(property: "og:image", in: html)
                
                if let ogTitleClean = ogTitle {
                    artistName = ogTitleClean.replacingOccurrences(of: "| Spotify", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if artworkURL == nil {
                    artworkURL = artwork.flatMap(URL.init(string:))
                }
            }
            
            return DownloadArtist(
                id: fallbackID,
                name: artistName,
                provider: .metadata,
                artworkURL: artworkURL
            )
        } catch {
            log("Spotify public page artist fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchSpotifyPlaylist(id: String, sourceURL: String) async -> (DownloadAlbum, [DownloadTrack])? {
        if let token = await fetchSpotifyToken() {
            guard let url = URL(string: "https://api.spotify.com/v1/playlists/\(id)") else { return nil }
            var playlistRequest = URLRequest(url: url)
            playlistRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (playlistData, response) = try await session.data(for: playlistRequest)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: playlistData) as? [String: Any] {
                    
                    let playlistName = json["name"] as? String ?? "Unknown Playlist"
                    let description = json["description"] as? String ?? "Spotify Playlist"
                    let artworkURLString = (json["images"] as? [[String: Any]])?.first?["url"] as? String
                    let artworkURL = artworkURLString.flatMap(URL.init(string:))
                    
                    let playlistResult = DownloadAlbum(
                        id: id,
                        name: playlistName,
                        artistLine: description,
                        artworkURL: artworkURL,
                        sourceURL: sourceURL,
                        provider: .metadata,
                        artistIdentifier: nil,
                        albumIdentifier: id
                    )
                    
                    var tracks: [DownloadTrack] = []
                    
                    if let tracksContainer = json["tracks"] as? [String: Any],
                       let items = tracksContainer["items"] as? [[String: Any]] {
                        for item in items {
                            if let track = item["track"] as? [String: Any],
                               let trackID = track["id"] as? String {
                                let trackName = track["name"] as? String ?? "Unknown Title"
                                let trackArtists = track["artists"] as? [[String: Any]] ?? []
                                let trackArtistLine = trackArtists.compactMap { $0["name"] as? String }.joined(separator: ", ")
                                let explicit = track["explicit"] as? Bool ?? false
                                let trackURL = "https://open.spotify.com/track/\(trackID)"
                                let trackAlbum = track["album"] as? [String: Any]
                                let trackAlbumName = trackAlbum?["name"] as? String ?? "Unknown Album"
                                let trackArtworkURLString = (trackAlbum?["images"] as? [[String: Any]])?.first?["url"] as? String
                                let trackArtworkURL = trackArtworkURLString.flatMap(URL.init(string:))
                                
                                tracks.append(DownloadTrack(
                                    id: trackID,
                                    name: trackName,
                                    artistLine: trackArtistLine.isEmpty ? "Unknown Artist" : trackArtistLine,
                                    albumName: trackAlbumName,
                                    artworkURL: trackArtworkURL ?? artworkURL,
                                    isExplicit: explicit,
                                    sourceURL: trackURL,
                                    sourceContext: .song,
                                    provider: .metadata,
                                    artistIdentifier: nil,
                                    albumIdentifier: trackAlbum?["id"] as? String,
                                    previewURL: (track["preview_url"] as? String).flatMap(URL.init(string:))
                                ))
                            }
                        }
                    }
                    
                    return (playlistResult, tracks)
                }
            } catch {
                log("Spotify API playlist fetch failed: \(error.localizedDescription)")
            }
        }
        return await fetchSpotifyPlaylistFromPublicPage(sourceURL: sourceURL, fallbackID: id)
    }

    private func fetchSpotifyArtist(id: String, sourceURL: String) async -> DownloadArtist? {
        if let token = await fetchSpotifyToken() {
            guard let url = URL(string: "https://api.spotify.com/v1/artists/\(id)") else { return nil }
            var artistRequest = URLRequest(url: url)
            artistRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (artistData, response) = try await session.data(for: artistRequest)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: artistData) as? [String: Any] {
                    
                    let name = json["name"] as? String ?? "Unknown Artist"
                    let artworkURLString = (json["images"] as? [[String: Any]])?.first?["url"] as? String
                    let artworkURL = artworkURLString.flatMap(URL.init(string:))
                    
                    return DownloadArtist(
                        id: id,
                        name: name,
                        provider: .metadata,
                        artworkURL: artworkURL
                    )
                }
            } catch {
                log("Spotify API artist fetch failed: \(error.localizedDescription)")
            }
        }
        return await fetchSpotifyArtistFromPublicPage(sourceURL: sourceURL, fallbackID: id)
    }

    private func tidalBaseURLCandidates() async -> [String] {
        var candidates: [String] = []

        if let activeTidalSearchHost {
            let stripped = activeTidalSearchHost.replacingOccurrences(of: "/search/", with: "")
            if !stripped.isEmpty {
                candidates.append(stripped)
            }
        }

        let rotated = await rotatedTidalTrackBackends().map(\.baseURL)
        candidates.append(contentsOf: rotated)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func parseTidalTrackMetadata(title: String?, description: String?) -> (title: String?, artist: String?, album: String?) {
        let cleanedTitle = title?
            .replacingOccurrences(of: "| TIDAL", with: "")
            .replacingOccurrences(of: " on TIDAL", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var parsedTitle = cleanedTitle
        var parsedArtist: String?
        var parsedAlbum: String?

        if let cleanedTitle, let byRange = cleanedTitle.range(of: " by ", options: .caseInsensitive) {
            parsedTitle = String(cleanedTitle[..<byRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            parsedArtist = String(cleanedTitle[byRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let cleanedTitle,
           parsedArtist == nil,
           let dashRange = cleanedTitle.range(of: " - "),
           dashRange.lowerBound != cleanedTitle.startIndex,
           dashRange.upperBound != cleanedTitle.endIndex {
            let left = String(cleanedTitle[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(cleanedTitle[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !left.isEmpty, !right.isEmpty {
                parsedArtist = left
                parsedTitle = right
            }
        }

        if let description {
            if parsedArtist == nil,
               let match = firstRegexCapture(
                in: description,
                pattern: #"(?i)(?:listen to|stream|watch)\s+(.+?)\s+by\s+(.+?)(?:\s+on\s+tidal|\s+from\s+the\s+album|\.)"#,
                group: 2
               ) {
                parsedArtist = match.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if (parsedTitle == nil || parsedTitle?.isEmpty == true),
               let match = firstRegexCapture(
                in: description,
                pattern: #"(?i)(?:listen to|stream|watch)\s+(.+?)\s+by\s+(.+?)(?:\s+on\s+tidal|\s+from\s+the\s+album|\.)"#,
                group: 1
               ) {
                parsedTitle = match.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let albumMatch = firstRegexCapture(
                in: description,
                pattern: #"(?i)from\s+the\s+album\s+(.+?)(?:\.|$)"#,
                group: 1
            ) {
                parsedAlbum = albumMatch.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        parsedArtist = parsedArtist?
            .replacingOccurrences(of: "| TIDAL", with: "")
            .replacingOccurrences(of: " on TIDAL", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        parsedAlbum = parsedAlbum?
            .replacingOccurrences(of: "| TIDAL", with: "")
            .replacingOccurrences(of: " on TIDAL", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (parsedTitle, parsedArtist, parsedAlbum)
    }

    private func extractHTMLMetaContent(property: String, in html: String) -> String? {
        let patterns = [
            #"<meta[^>]*property=["']\#(property)["'][^>]*content=["']([^"']+)["'][^>]*>"#,
            #"<meta[^>]*content=["']([^"']+)["'][^>]*property=["']\#(property)["'][^>]*>"#
        ]

        for pattern in patterns {
            if let value = firstRegexCapture(in: html, pattern: pattern, group: 1) {
                return htmlDecoded(value)
            }
        }

        return nil
    }

    private func extractHTMLMetaContent(name: String, in html: String) -> String? {
        let patterns = [
            #"<meta[^>]*name=["']\#(name)["'][^>]*content=["']([^"']+)["'][^>]*>"#,
            #"<meta[^>]*content=["']([^"']+)["'][^>]*name=["']\#(name)["'][^>]*>"#
        ]

        for pattern in patterns {
            if let value = firstRegexCapture(in: html, pattern: pattern, group: 1) {
                return htmlDecoded(value)
            }
        }

        return nil
    }

    private func extractHTMLTagContent(tag: String, in html: String) -> String? {
        let pattern = #"<\#(tag)[^>]*>(.*?)</\#(tag)>"#
        guard let value = firstRegexCapture(in: html, pattern: pattern, group: 1) else {
            return nil
        }
        return htmlDecoded(value)
    }

    private func firstRegexCapture(in text: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func htmlDecoded(_ value: String) -> String {
        let data = Data(value.utf8)
        if let decoded = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ).string {
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func regexMatches(in text: String, pattern: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match in
            guard group < match.numberOfRanges,
                  let range = Range(match.range(at: group), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func extractSpotifyTracksFromHTML(in html: String, fallbackArtist: String, fallbackAlbumName: String, artworkURL: URL?, sourceContext: DownloadTrack.SourceContext) -> [DownloadTrack] {
        var tracks: [DownloadTrack] = []
        let segments = html.components(separatedBy: "data-testid=\"track-row\"")
        guard segments.count > 1 else { return [] }
        
        for segment in segments.dropFirst() {
            // Extract track ID
            guard let trackID = firstRegexCapture(in: segment, pattern: #"href=["']/track/([a-zA-Z0-9]+)["']"#, group: 1) else {
                continue
            }
            // Extract track title
            guard let title = firstRegexCapture(in: segment, pattern: #"<span[^>]*>([^<]+)</span>"#, group: 1) else {
                continue
            }
            
            // Extract artists: find all href="/artist/[a-zA-Z0-9]+" links and get their content
            let artistPattern = #"href=["']/artist/[a-zA-Z0-9]+["'][^>]*>([^<]+)</a>"#
            let artistNames = regexMatches(in: segment, pattern: artistPattern, group: 1)
            let artistLine = artistNames.joined(separator: ", ")
            
            let trackURL = "https://open.spotify.com/track/\(trackID)"
            
            tracks.append(
                DownloadTrack(
                    id: trackID,
                    name: htmlDecoded(title),
                    artistLine: artistLine.isEmpty ? fallbackArtist : htmlDecoded(artistLine),
                    albumName: fallbackAlbumName,
                    artworkURL: artworkURL,
                    isExplicit: false,
                    sourceURL: trackURL,
                    sourceContext: sourceContext,
                    provider: .metadata,
                    artistIdentifier: nil,
                    albumIdentifier: nil,
                    previewURL: nil
                )
            )
        }
        return tracks
    }

    private func parseSpotifyEmbedHTML(in html: String, fallbackID: String, sourceURL: String, sourceContext: DownloadTrack.SourceContext) -> (album: DownloadAlbum, tracks: [DownloadTrack])? {
        let pattern = #"<script[^>]*id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>"#
        guard let jsonString = firstRegexCapture(in: html, pattern: pattern, group: 1),
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = json["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any],
              let stateData = state["data"] as? [String: Any],
              let entity = stateData["entity"] as? [String: Any] else {
            return nil
        }
        
        let entityName = entity["name"] as? String ?? entity["title"] as? String ?? "Unknown Name"
        let subtitle = entity["subtitle"] as? String ?? ""
        
        var artworkURL: URL?
        if let coverArt = entity["coverArt"] as? [String: Any],
           let sources = coverArt["sources"] as? [[String: Any]],
           let firstSource = sources.first,
           let urlStr = firstSource["url"] as? String {
            artworkURL = URL(string: urlStr)
        }
        
        let albumResult = DownloadAlbum(
            id: fallbackID,
            name: entityName,
            artistLine: subtitle.isEmpty ? (sourceContext == .album ? "Unknown Artist" : "Spotify Playlist") : subtitle,
            artworkURL: artworkURL,
            sourceURL: sourceURL,
            provider: .metadata,
            artistIdentifier: nil,
            albumIdentifier: fallbackID
        )
        
        var parsedTracks: [DownloadTrack] = []
        if let trackList = entity["trackList"] as? [[String: Any]] {
            for trackObj in trackList {
                let uri = trackObj["uri"] as? String ?? ""
                let trackID: String
                if uri.hasPrefix("spotify:track:") {
                    trackID = String(uri.dropFirst("spotify:track:".count))
                } else {
                    continue
                }
                
                let title = trackObj["title"] as? String ?? "Unknown Title"
                let artists = trackObj["subtitle"] as? String ?? ""
                let explicit = trackObj["isExplicit"] as? Bool ?? false
                let trackURL = "https://open.spotify.com/track/\(trackID)"
                
                let previewURLString = (trackObj["audioPreview"] as? [String: Any])?["url"] as? String
                let previewURL = previewURLString.flatMap(URL.init(string:))
                
                parsedTracks.append(
                    DownloadTrack(
                        id: trackID,
                        name: htmlDecoded(title),
                        artistLine: artists.isEmpty ? (subtitle.isEmpty ? "Unknown Artist" : subtitle) : htmlDecoded(artists),
                        albumName: sourceContext == .album ? entityName : "Unknown Album",
                        artworkURL: artworkURL,
                        isExplicit: explicit,
                        sourceURL: trackURL,
                        sourceContext: sourceContext,
                        provider: .metadata,
                        artistIdentifier: nil,
                        albumIdentifier: sourceContext == .album ? fallbackID : nil,
                        previewURL: previewURL
                    )
                )
            }
        }
        
        return (albumResult, parsedTracks)
    }

    private func preferredTidalBaseURL() async -> String? {
        if let activeTidalSearchHost {
            return activeTidalSearchHost.replacingOccurrences(of: "/search/", with: "")
        }
        let backends = await rotatedTidalTrackBackends()
        return backends.first?.baseURL
    }

    private func uniqueAlbums(_ albums: [DownloadAlbum]) -> [DownloadAlbum] {
        var seen = Set<String>()
        return albums.filter { album in
            let key = "\(album.provider.rawValue)|\(DownloadSupport.normalizedSearchValue(album.artistLine))|\(DownloadSupport.normalizedSearchValue(album.name))"
            return seen.insert(key).inserted
        }
    }

    private func uniqueTracks(_ tracks: [DownloadTrack]) -> [DownloadTrack] {
        var seen = Set<String>()
        return tracks.filter { track in
            let key = "\(track.provider.rawValue)|\(DownloadSupport.normalizedSearchValue(track.artistLine))|\(DownloadSupport.normalizedSearchValue(track.albumName))|\(DownloadSupport.normalizedSearchValue(track.name))"
            return seen.insert(key).inserted
        }
    }

    private func uniqueTracksForMetadataProfile(_ tracks: [DownloadTrack]) -> [DownloadTrack] {
        var seen = Set<String>()
        return tracks.filter { track in
            let key = "\(DownloadSupport.normalizedSearchValue(track.artistLine))|\(DownloadSupport.normalizedSearchValue(track.albumName))|\(DownloadSupport.normalizedSearchValue(track.name))"
            return seen.insert(key).inserted
        }
    }

    private func uniqueAlbumsForMetadataProfile(_ albums: [DownloadAlbum]) -> [DownloadAlbum] {
        var seen = Set<String>()
        return albums.filter { album in
            let key = "\(DownloadSupport.normalizedSearchValue(album.artistLine))|\(DownloadSupport.normalizedSearchValue(album.name))"
            return seen.insert(key).inserted
        }
    }

    private func matchesArtistLine(_ artistLine: String, artistName: String) -> Bool {
        let target = DownloadSupport.normalizedSearchValue(artistName)
        let normalizedLine = DownloadSupport.normalizedSearchValue(artistLine)
        guard !target.isEmpty, !normalizedLine.isEmpty else { return false }
        if normalizedLine == target { return true }
        let tokens = DownloadSupport.artistTokens(from: artistLine)
        return tokens.contains(where: { $0 == target || $0.contains(target) || target.contains($0) })
    }

    private func log(_ message: String) {
        Logger.shared.log("[Download] \(message)")
    }

    private func restorePersistedQueue() {
        guard let snapshot = QueuePersistenceStore.loadDownloadQueue() else { return }

        let restoredTracks = snapshot.tracksByID.compactMapValues(\.downloadTrack)
        guard !restoredTracks.isEmpty else {
            QueuePersistenceStore.clearDownloadQueue()
            return
        }

        knownTracksByID = restoredTracks
        queueOrder = snapshot.queueOrder.filter { restoredTracks[$0] != nil }
        totalQueueCount = snapshot.totalQueueCount
        completedQueueCount = snapshot.completedQueueCount

        for id in snapshot.failedIDs where restoredTracks[id] != nil {
            trackStates[id] = .failed
        }

        let activeAsQueued = snapshot.activeID.map { [$0] } ?? []
        let pendingIDs = (activeAsQueued + snapshot.pendingIDs).filter { restoredTracks[$0] != nil }
        pendingQueue = pendingIDs.compactMap { id in
            trackStates[id] = .queued
            return restoredTracks[id]
        }

        if totalQueueCount == 0 && (!pendingQueue.isEmpty || !snapshot.failedIDs.isEmpty) {
            totalQueueCount = pendingQueue.count + snapshot.failedIDs.count
        }
        completedQueueCount = min(completedQueueCount, totalQueueCount)

        if !pendingQueue.isEmpty {
            log("Restored \(pendingQueue.count) queued download(s) from last session.")
            Task { await processQueueIfNeeded() }
        } else if !snapshot.failedIDs.isEmpty {
            log("Restored \(snapshot.failedIDs.count) failed download(s) from last session.")
        }
    }

    private func syncQueuePersistence() {
        let failedIDs = queueOrder.filter { trackStates[$0] == .failed }
        let pendingIDs = pendingQueue.map(\.id)
        let hasMeaningfulState = !pendingIDs.isEmpty || activeDownloadTrackID != nil || !failedIDs.isEmpty

        guard hasMeaningfulState else {
            QueuePersistenceStore.clearDownloadQueue()
            return
        }

        let snapshot = PersistedDownloadQueue(
            tracksByID: knownTracksByID.mapValues(PersistedDownloadTrack.init),
            queueOrder: queueOrder,
            pendingIDs: pendingIDs,
            failedIDs: failedIDs,
            activeID: activeDownloadTrackID,
            totalQueueCount: totalQueueCount,
            completedQueueCount: completedQueueCount
        )
        QueuePersistenceStore.saveDownloadQueue(snapshot)
    }

    func queueSnapshot() -> DownloadQueueSnapshot {
        var items: [DownloadQueueSnapshot.Item] = []
        for id in queueOrder {
            guard let track = knownTracksByID[id] else { continue }
            let state = trackStates[id] ?? .idle
            guard state != .idle else { continue }

            let queueIndex = pendingQueue.firstIndex(where: { $0.id == id })
            items.append(
                .init(
                    id: id,
                    name: track.name,
                    artist: track.artistLine,
                    album: track.albumName,
                    state: state,
                    isActive: activeDownloadTrackID == id,
                    queueIndex: queueIndex
                )
            )
        }

        let activeItems = items.filter { $0.isActive }
        let queuedItems = items.filter { $0.queueIndex != nil && !$0.isActive }
            .sorted { ($0.queueIndex ?? 0) < ($1.queueIndex ?? 0) }
        let doneItems = items.filter { $0.state == .done }
        let failedItems = items.filter { $0.state == .failed }

        return DownloadQueueSnapshot(
            activeItems: activeItems,
            queuedItems: queuedItems,
            doneItems: doneItems,
            failedItems: failedItems,
            currentSongProgress: currentSongProgress,
            queueCounterText: queueCounterText,
            currentDownloadSpeedBps: currentDownloadSpeedBps
        )
    }
}

struct DownloadQueueSnapshot {
    struct Item: Identifiable {
        let id: String
        let name: String
        let artist: String
        let album: String
        let state: DownloadTrackState
        let isActive: Bool
        let queueIndex: Int?
    }

    let activeItems: [Item]
    let queuedItems: [Item]
    let doneItems: [Item]
    let failedItems: [Item]
    let currentSongProgress: Double
    let queueCounterText: String
    let currentDownloadSpeedBps: Double
}

struct DownloadQueueDetailsSheet: View {
    @ObservedObject var vm: DownloadViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshot = vm.queueSnapshot()

        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        DownloadQueueIndicator(
                            progress: snapshot.currentSongProgress,
                            label: snapshot.queueCounterText
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download Queue")
                                .font(.headline)
                            
                            HStack(spacing: 8) {
                                if vm.isPaused {
                                    Button {
                                        vm.resumeQueue()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "play.fill")
                                                .font(.caption)
                                            Text("Resume")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .stroke(Color.green.opacity(0.4), lineWidth: 1)
                                                .background(Color.green.opacity(0.08).clipShape(Capsule()))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                } else if vm.shouldShowPauseButton {
                                    Button {
                                        vm.pauseQueue()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "pause.fill")
                                                .font(.caption)
                                            Text("Pause")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                                                .background(Color.accentColor.opacity(0.08).clipShape(Capsule()))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                if vm.shouldShowCancelButton {
                                    Button {
                                        vm.cancelQueue()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                            Text("Cancel All")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .foregroundColor(.red)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                                                .background(Color.red.opacity(0.08).clipShape(Capsule()))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if !snapshot.activeItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Current Progress")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(snapshot.currentSongProgress * 100))%")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: snapshot.currentSongProgress)
                                .tint(.accentColor)
                            HStack {
                                Text("Speed")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formattedSpeed(snapshot.currentDownloadSpeedBps))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                }

                if !snapshot.activeItems.isEmpty {
                    Section("In Progress") {
                        ForEach(snapshot.activeItems) { item in
                            queueRow(item)
                        }
                    }
                }

                if !snapshot.queuedItems.isEmpty {
                    Section("Queued") {
                        ForEach(snapshot.queuedItems) { item in
                            queueRow(item)
                        }
                        .onDelete { offsets in
                            let items = snapshot.queuedItems
                            for index in offsets {
                                vm.removeQueued(trackID: items[index].id)
                            }
                        }
                    }
                }

                if !snapshot.doneItems.isEmpty {
                    Section("Completed") {
                        ForEach(snapshot.doneItems) { item in
                            queueRow(item)
                        }
                    }
                }

                if !snapshot.failedItems.isEmpty {
                    Section("Failed") {
                        ForEach(snapshot.failedItems) { item in
                            queueRow(item)
                        }
                        .onDelete { offsets in
                            let items = snapshot.failedItems
                            for index in offsets {
                                vm.removeFailed(trackID: items[index].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Queue Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func queueRow(_ item: DownloadQueueSnapshot.Item) -> some View {
        HStack(spacing: 12) {
            Group {
                switch item.state {
                case .downloading:
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                case .queued:
                    Image(systemName: "clock.fill").foregroundStyle(.orange)
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Button {
                        vm.retry(trackID: item.id)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                case .idle:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.album)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let queueIndex = item.queueIndex, !item.isActive {
                Text("#\(queueIndex + 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func formattedSpeed(_ bps: Double) -> String {
        guard bps > 0 else { return "0 KB/s" }
        let kb = bps / 1024
        if kb < 1024 {
            return String(format: "%.0f KB/s", kb)
        }
        return String(format: "%.2f MB/s", kb / 1024)
    }
}

private final class ProgressiveDataFetcher: NSObject, URLSessionDataDelegate {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var receivedData = Data()
    private var response: URLResponse?
    private var expectedLength: Int64 = -1
    private var progressHandler: ((Double, Double) -> Void)?
    private var session: URLSession?
    private var startedAt: CFAbsoluteTime = 0
    private var lastSampleAt: CFAbsoluteTime = 0
    private var lastSampleBytes: Int = 0
    private var smoothedSpeedBps: Double = 0
    private var task: URLSessionDataTask?

    func fetch(
        request: URLRequest,
        progress: @escaping (Double, Double) -> Void
    ) async throws -> (Data, URLResponse) {
        progressHandler = progress
        receivedData = Data()
        expectedLength = -1
        response = nil
        startedAt = CFAbsoluteTimeGetCurrent()
        lastSampleAt = startedAt
        lastSampleBytes = 0
        smoothedSpeedBps = 0

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                continuation = cont
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        self.expectedLength = response.expectedContentLength
        if let progressHandler {
            DispatchQueue.main.async {
                progressHandler(0, 0)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedSinceLastSample = max(now - lastSampleAt, 0.001)
        let bytesSinceLastSample = max(receivedData.count - lastSampleBytes, 0)
        let instantaneousSpeedBps = Double(bytesSinceLastSample) / elapsedSinceLastSample

        if smoothedSpeedBps == 0 {
            smoothedSpeedBps = instantaneousSpeedBps
        } else {
            smoothedSpeedBps = (smoothedSpeedBps * 0.65) + (instantaneousSpeedBps * 0.35)
        }

        lastSampleAt = now
        lastSampleBytes = receivedData.count

        if expectedLength > 0 {
            let fraction = Double(receivedData.count) / Double(expectedLength)
            if let progressHandler {
                let value = max(0, min(fraction, 1))
                DispatchQueue.main.async {
                    progressHandler(value, self.smoothedSpeedBps)
                }
            }
        } else if let progressHandler {
            DispatchQueue.main.async {
                progressHandler(0, self.smoothedSpeedBps)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }

        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }

        guard let response else {
            continuation?.resume(throwing: DownloadError.emptyResponse)
            continuation = nil
            return
        }

        if let progressHandler {
            DispatchQueue.main.async {
                progressHandler(1, self.smoothedSpeedBps)
            }
        }
        continuation?.resume(returning: (receivedData, response))
        continuation = nil
    }
}

private struct AppleMusicAlbumSearchResponse: Decodable {
    let results: AppleMusicAlbumSearchResults?
    let errors: [AppleMusicAlbumSearchError]?
}

private struct AppleMusicAlbumSearchResults: Decodable {
    let albums: AppleMusicAlbumPage?
}

private struct AppleMusicAlbumSearchError: Decodable {
    let id: String?
    let title: String?
    let detail: String?
    let status: String?
    let code: String?
}

private struct AppleMusicAlbumPage: Decodable {
    let data: [AppleMusicAlbumResult]
}

private struct AppleMusicAlbumResult: Decodable {
    let id: String
    let attributes: AppleMusicAlbumResultAttributes
}

private struct AppleMusicAlbumResultAttributes: Decodable {
    let name: String
    let artistName: String
    let artwork: AppleMusicAPI.AppleMusicArtwork?
}

private struct AppleMusicPlaylistSearchResponse: Decodable {
    let results: AppleMusicPlaylistSearchResults?
    let errors: [AppleMusicAlbumSearchError]?
}

private struct AppleMusicPlaylistSearchResults: Decodable {
    let playlists: AppleMusicPlaylistPage?
}

private struct AppleMusicPlaylistPage: Decodable {
    let data: [AppleMusicPlaylistResult]
}

private struct AppleMusicAlbumDetailsResponse: Decodable {
    let data: [AppleMusicAlbumDetailsData]
}

private struct AppleMusicAlbumDetailsData: Decodable {
    let id: String?
    let attributes: AppleMusicDirectAlbumAttributes?
    let relationships: AppleMusicAlbumRelationships?
}

private struct AppleMusicDirectAlbumAttributes: Decodable {
    let name: String
    let artistName: String
    let artwork: AppleMusicAPI.AppleMusicArtwork?
    let playParams: AppleMusicPlayParams?
}

private struct AppleMusicPlayParams: Decodable {
    let id: String?
}

private struct AppleMusicAlbumRelationships: Decodable {
    let tracks: AppleMusicAlbumTracksPage?
}

private struct AppleMusicAlbumTracksPage: Decodable {
    let data: [AppleMusicAlbumTrack]
}

private struct AppleMusicAlbumTrack: Decodable {
    let id: String
    let attributes: AppleMusicAlbumTrackAttributes
}

private struct AppleMusicAlbumTrackAttributes: Decodable {
    let name: String
    let artistName: String
    let albumName: String?
    let url: String?
    let contentRating: String?
    let artwork: AppleMusicAPI.AppleMusicArtwork?
}

private struct AppleMusicArtistResponse: Decodable {
    let data: [AppleMusicArtistResult]
}

private struct AppleMusicArtistResult: Decodable {
    let id: String
    let attributes: AppleMusicArtistAttributes
}

private struct AppleMusicArtistAttributes: Decodable {
    let name: String
    let artwork: AppleMusicAPI.AppleMusicArtwork?
}

private struct AppleMusicPlaylistResponse: Decodable {
    let data: [AppleMusicPlaylistResult]
}

private struct AppleMusicPlaylistResult: Decodable {
    let id: String
    let attributes: AppleMusicPlaylistAttributes
    let relationships: AppleMusicPlaylistRelationships?
}

private struct AppleMusicPlaylistAttributes: Decodable {
    let name: String
    let curatorName: String?
    let artwork: AppleMusicAPI.AppleMusicArtwork?
}

private struct AppleMusicPlaylistRelationships: Decodable {
    let tracks: AppleMusicPlaylistTracksPage?
}

private struct AppleMusicPlaylistTracksPage: Decodable {
    let data: [AppleMusicAPI.AppleMusicSong]
}

private struct TidalSearchResponse: Decodable {
    let data: TidalSearchData
}

private struct TidalSearchData: Decodable {
    let limit: Int?
    let offset: Int?
    let totalNumberOfItems: Int
    let items: [TidalSearchItem]
}

private struct TidalSearchItem: Decodable {
    let id: Int
    let title: String
    let version: String?
    let url: String?
    let explicit: Bool?
    let audioQuality: String?
    let artist: TidalSearchArtist?
    let artists: [TidalSearchArtist]?
    let album: TidalSearchAlbum?
}

private struct TidalSearchArtist: Decodable {
    let id: Int?
    let name: String
    let picture: String?
}

private struct TidalSearchAlbum: Decodable {
    let id: Int?
    let title: String
    let cover: String?
}

private struct TidalAlbumResponse: Decodable {
    let data: TidalAlbumPayload
}

private struct TidalAlbumPayload: Decodable {
    let id: Int
    let title: String
    let cover: String?
    let explicit: Bool?
    let items: [TidalAlbumItemWrapper]
}

private struct TidalAlbumItemWrapper: Decodable {
    let item: TidalSearchItem
    let type: String?
}

private struct TidalArtistAlbumsResponse: Decodable {
    let artist: TidalArtistDetail?
    let albums: TidalArtistAlbumList
}

private struct TidalArtistDetail: Decodable {
    let id: Int
    let name: String
    let picture: String?
}

private struct TidalArtistAlbumList: Decodable {
    let items: [TidalArtistAlbum]
}

private struct TidalArtistAlbum: Decodable {
    let id: Int
    let title: String
    let url: String?
    let cover: String?
    let artist: TidalSearchArtist?
}

private struct QobuzSearchResponse: Decodable {
    let tracks: QobuzSearchTrackList
}

private struct QobuzSearchTrackList: Decodable {
    let total: Int?
    let items: [QobuzSearchTrackItem]
}

private struct QobuzSearchTrackItem: Decodable {
    let id: Int
    let title: String
    let version: String?
    let isrc: String?
    let duration: Int?
    let downloadable: Bool?
    let performer: QobuzSearchArtistInfo?
    let album: QobuzSearchAlbumInfo
}

private struct QobuzSearchArtistInfo: Decodable {
    let id: Int?
    let name: String
}

private struct QobuzSearchAlbumInfo: Decodable {
    let id: String
    let title: String
    let artist: QobuzSearchArtistInfo
}
