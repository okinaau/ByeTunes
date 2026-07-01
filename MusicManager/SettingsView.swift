import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var manager: DeviceManager
    @Binding var status: String
    
    @State private var showingPairingPicker = false
    @State private var showingDownloadFolderPicker = false
    @State private var showingDownloaderSettings = false
    @State private var showingDeleteAlert = false
    
    @State private var showingLogViewer = false
    @State private var exportedDbURLs: [URL] = []
    @State private var showingDbExportSheet = false
    @State private var isExportingDb = false
    @State private var isSnapshotBusy = false
    @State private var isCreatingSnapshot = false
    @State private var isRestoringSnapshot = false
    @State private var snapshotProgressTitle = "Working on Backup"
    @State private var snapshotProgressMessage = "Preparing..."
    @State private var snapshotProgress: Double? = nil
    @State private var isFixingArtwork = false
    @State private var isRebuildingAlbumArtwork = false
    @State private var showingM3UImportPicker = false
    @State private var showingPlaylistNameAlert = false
    @State private var playlistNameToExport = ""
    @State private var m3uExportURLs: [URL] = []
    @State private var showingM3UExportSheet = false
    @State private var isProcessingM3U = false
    @State private var artworkFixMessage = "Fixing artwork..."
    @State private var artworkFixProgress: Double? = nil
    @State private var snapshots: [DeviceManager.DatabaseSnapshotInfo] = []
    @State private var isCheckingForUpdate = false
    @State private var settingsUpdate: AppUpdateInfo?
    @State private var supporters: [String] = []
    @State private var supportersLoaded = false
    
    @State private var showToast = false
    @State private var toastTitle = ""
    @State private var toastIcon = ""

    @AppStorage("metadataSource") private var metadataSource = "local"
    @AppStorage("autofetchMetadata") private var autofetchMetadata = true
    @AppStorage("fetchLyrics") private var fetchLyrics = false
    @AppStorage("appleSubscriptionLyrics") private var appleSubscriptionLyrics = false
    @AppStorage("storeRegion") private var storeRegion = "US"
    @AppStorage("appleRichMetadata") private var appleRichMetadata = true
    @AppStorage("keepDownloadedSongs") private var keepDownloadedSongs = false
    @AppStorage("fullBackupSnapshots") private var fullBackupSnapshots = false
    @AppStorage("downloadServer") private var downloadServer = DownloaderServerPreference.byeTunesAPI.rawValue
    @AppStorage("downloadSearchProvider") private var downloadSearchProvider = DownloadSearchProviderOption.appleMusic.rawValue
    @AppStorage("autoDownloadTier") private var autoDownloadTier = "high"
    @AppStorage("yoinkifyFormat") private var yoinkifyFormat = "flac"
    @AppStorage("qobuzFallbackQuality") private var qobuzFallbackQuality = "27"
    @AppStorage("tidalFallbackQuality") private var tidalFallbackQuality = "LOSSLESS"
    
    var body: some View {
        NavigationStack {
        ZStack(alignment: .bottom) {   // ← outer ZStack: lets popups layer over content

        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                
                Text("Settings")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.top, 8)
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("CONNECTION")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        
                        Button {
                            showingPairingPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "link")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(manager.expectedPairingFileTitle)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(manager.connectionStatus)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        
                        Divider().padding(.leading, 56)
                        
                        
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)
                            
                            Text("Status")
                                .font(.body)
                            
                            Spacer()
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(manager.heartbeatReady ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(manager.connectionStatus)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Button {
                                    manager.startHeartbeat(forceReconnect: true)
                                } label: {
                                    Text("Refresh")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                                .padding(.leading, 8)
                                .disabled(!manager.hasValidExpectedPairingFile)
                                .opacity(manager.hasValidExpectedPairingFile ? 1 : 0.55)
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("ABOUT")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        Button {
                            if let settingsUpdate {
                                openURL(settingsUpdate.releaseURL)
                            } else {
                                checkForSettingsUpdate()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "info.circle")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Version")
                                        .font(.body)
                                        .foregroundColor(.primary)

                                    Text(settingsUpdate == nil ? "Tap to check for updates" : "Tap to download the latest release")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if isCheckingForUpdate {
                                    ProgressView()
                                } else {
                                    Text(settingsUpdate.map { "Update \($0.version)" } ?? AppUpdateChecker.currentVersion)
                                        .font(.subheadline)
                                        .foregroundColor(settingsUpdate == nil ? .secondary : .accentColor)
                                }
                            }
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .disabled(isCheckingForUpdate)
                        
                        Divider().padding(.leading, 56)
                        
                        HStack {
                            Image(systemName: "music.note")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)
                            
                            Text("Music Formats")
                                .font(.body)
                            
                            Spacer()
                            
                            Text("MP3, FLAC, M4A, WAV")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        
                        Divider().padding(.leading, 56)
                        
                        HStack {
                            Image(systemName: "bell.badge")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)
                            
                            Text("Ringtone Formats")
                                .font(.body)
                            
                            Spacer()
                            
                            Text("M4R, MP3 (Ringtones injection disabled for now")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }
                
                
                
                
                if manager.supportsIOS26ArtworkRepair {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("IOS 26.4+")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .tracking(0.5)

                        VStack(spacing: 0) {
                            Button {
                                fixArtwork()
                            } label: {
                                HStack {
                                    if isFixingArtwork {
                                        ProgressView()
                                            .frame(width: 28)
                                    } else {
                                        Image(systemName: "photo.on.rectangle.angled")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .frame(width: 28)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isFixingArtwork ? "Fixing Artwork..." : "Fix Artwork")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("Fix artwork and colors for songs added before iOS 26.4. Internet required.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if !isFixingArtwork {
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(Color(.systemGray3))
                                    }
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                            }
                            .disabled(isFixingArtwork || !manager.hasValidExpectedPairingFile)
                            .opacity((isFixingArtwork || manager.hasValidExpectedPairingFile) ? 1 : 0.55)

                            Divider().padding(.leading, 56)

                            Button {
                                rebuildAlbumArtworkExperimental()
                            } label: {
                                HStack {
                                    if isRebuildingAlbumArtwork {
                                        ProgressView()
                                            .frame(width: 28)
                                    } else {
                                        Image(systemName: "wrench.and.screwdriver")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                            .frame(width: 28)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(isRebuildingAlbumArtwork ? "Running Advanced Artwork & Metadata Fix..." : "Advanced Artwork & Metadata Fix")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("Deeper repair for missing artwork/info. Can take a while.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if !isRebuildingAlbumArtwork {
                                        Image(systemName: "flask")
                                            .font(.caption)
                                            .foregroundColor(Color(.systemOrange))
                                    }
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                            }
                            .disabled(isRebuildingAlbumArtwork || !manager.hasValidExpectedPairingFile)
                            .opacity((isRebuildingAlbumArtwork || manager.hasValidExpectedPairingFile) ? 1 : 0.55)
                        }
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray5), lineWidth: 1)
                        )
                    }
                }

                
                VStack(alignment: .leading, spacing: 12) {
                    Text("DOWNLOADS")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        Button {
                            showingDownloaderSettings = true
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Metadata & Download Settings")
                                        .font(.body)
                                    Text("Metadata source, downloader, quality, and saved downloads")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("DEVICE LIBRARY")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        NavigationLink {
                            DeviceLibraryBrowserView(manager: manager)
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("On-Device Library")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("Edit, delete, and export songs already on the phone")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        .disabled(!manager.heartbeatReady)
                        .opacity(manager.heartbeatReady ? 1 : 0.55)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )

                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("SHORTCUTS")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        Link(destination: URL(string: "https://www.icloud.com/shortcuts/49de36f87bf44b21a38056d3c33e41fe")!) {
                            HStack {
                                Image(systemName: "bolt.fill")
                                    .font(.body)
                                    .foregroundColor(.purple)
                                    .frame(width: 28)
                                
                                Text("Add ByeTunes Shortcut")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("HELP & SUPPORT")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("1. Ensure you are connected to your Local Tunnel VPN (e.g., StosVPN, LocalDev VPN).")
                                Text("2. If connected after opening the app, press 'Retry' next to the 'Connecting' status.")
                                Text("3. Go to the Music tab.")
                                Text("4. Tap 'Add Songs' to select your audio files.")
                                Text("5. Tap 'Inject to Device' to sync them to your library.")
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundColor(.blue)
                                Text("How to Use")
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding()
                        
                        Divider().padding(.leading)
                        
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("• App Stuck on White/Black Screen?")
                                Text("  Restart your iPhone to force a library reload.")
                                Text("• Songs Not Showing Up?")
                                Text("  The songs likely didn't import correctly. Restart this app and try again.")
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("App Crashing / No Songs?")
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding()
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("• Artwork Disappeared?")
                                Text("  Restart the music app to refresh the cache.")
                                Text("• Song Not Injected?")
                                Text("  To prevent artwork mix-ups, 'Unknown' songs are skipped in batches. Inject them individually to add them.")
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: "photo.artframe")
                                    .foregroundColor(.purple)
                                Text("Artwork / Missing Songs")
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding()
                        
                        Divider().padding(.leading)
                        
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("• What is Auto-Inject?")
                                Text("  When you share audio files to MusicManager from other apps (like Files), they are automatically injected to your device if connected.")
                                Text("• Supported Music Formats:")
                                Text("  MP3, M4A, FLAC, WAV, AIFF")
                                Text("• Supported Ringtone Formats:")
                                Text("  M4R only (MP3 ringtones must be added manually inside the app)")
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: "square.and.arrow.down.on.square.fill")
                                    .foregroundColor(.green)
                                Text("Auto-Inject")
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding()


                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("CREDITS")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            
                            Link("EduAlexxis", destination: URL(string: "https://github.com/EduAlexxis")!)
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        
                        Divider().padding(.leading, 56)
                        
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.indigo)
                                .frame(width: 28)
                            
                            Link("stossy11", destination: URL(string: "https://github.com/stossy11")!)
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        
                        Divider().padding(.leading, 56)
                        
                        HStack(spacing: 12) {
                            Image(systemName: "paintbrush.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                                .frame(width: 28)
                            
                            Text("u/Zephyrax_g14")
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        
                        Divider().padding(.leading, 56)
                        
                        HStack(spacing: 12) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.gray)
                                .frame(width: 28)
                            
                            Link("jkcoxson", destination: URL(string: "https://github.com/jkcoxson/idevice")!)
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }
                
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("BACKUP & RESTORE")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        Toggle(isOn: $fullBackupSnapshots) {
                            HStack {
                                Image(systemName: "archivebox.fill")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Full Backup")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("Back up the database and song files locally. This can take time and use a lot of space.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)

                        Divider().padding(.leading, 56)

                        Button {
                            createSnapshotBackup()
                        } label: {
                            HStack {
                                if isCreatingSnapshot {
                                    ProgressView()
                                        .frame(width: 28)
                                } else {
                                    Image(systemName: "externaldrive.badge.plus")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)
                                }
                                
                                Text(isCreatingSnapshot ? "Working…" : "Create Snapshot/Backup")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                Divider().padding(.leading, 56)

                                Button {
                                    playlistNameToExport = ""
                                    showingPlaylistNameAlert = true
                                } label: {
                                    HStack {
                                        if isProcessingM3U {
                                            ProgressView()
                                                .frame(width: 28)
                                        } else {
                                            Image(systemName: "square.and.arrow.up.fill")
                                                .font(.body)
                                                .foregroundColor(.primary)
                                                .frame(width: 28)
                                        }

                                        Text(isProcessingM3U ? "Working…" : "Export Playlist (.m3u8)")
                                            .font(.body)
                                            .foregroundColor(.primary)

                                        Spacer()
                                    }
                                    .padding(.vertical, 14)
                                    .padding(.horizontal, 16)
                                }
                                .disabled(isProcessingM3U || !manager.heartbeatReady)

                                Divider().padding(.leading, 56)

                                Button {
                                    showingM3UImportPicker = true
                                } label: {
                                    HStack {
                                        if isProcessingM3U {
                                            ProgressView().frame(width: 28)
                                        } else {
                                            Image(systemName: "square.and.arrow.down.fill")
                                                .font(.body)
                                                .foregroundColor(.primary)
                                                .frame(width: 28)
                                        }
                                        Text(isProcessingM3U ? "Working…" : "Import Playlist (.m3u8)")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    .padding(.vertical, 14)
                                    .padding(.horizontal, 16)
                                }
                                .disabled(isProcessingM3U || !manager.heartbeatReady)
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        .disabled(isSnapshotBusy || !manager.heartbeatReady)
                        
                        Divider().padding(.leading, 56)
                        
                        Button {
                            restoreSnapshotBackup()
                        } label: {
                            HStack {
                                if isRestoringSnapshot {
                                    ProgressView()
                                        .frame(width: 28)
                                } else {
                                    Image(systemName: "arrow.counterclockwise.circle.fill")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)
                                }
                                
                                Text(isRestoringSnapshot ? "Working…" : "Restore Snapshot/Backup")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        .disabled(isSnapshotBusy || !manager.heartbeatReady)
                        
                        Divider().padding(.leading, 56)
                        
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last Backup")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                if let latest = snapshots.first {
                                    Text("\(latest.songCount) songs • \(formatSnapshotDate(latest.createdAt))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("No backup yet")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                    
                    Text(fullBackupSnapshots ? "Full backup stores a local copy of the database and media files. It can take time and use a lot of space." : "Database-only backup uses less space, but it cannot restore song files deleted by an external sync.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                }
                
                
                // ── DEBUG ──────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Text("DEBUG")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    VStack(spacing: 0) {
                        
                        Button {
                            showingLogViewer = true
                        } label: {
                            HStack {
                                Image(systemName: "terminal.fill")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)
                                
                                Text("Console")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        
                        Divider().padding(.leading, 56)
                        
                        Button {
                            exportDatabase()
                        } label: {
                            HStack {
                                if isExportingDb {
                                    ProgressView()
                                        .frame(width: 28)
                                } else {
                                    Image(systemName: "cylinder.split.1x2")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)
                                }
                                
                                Text(isExportingDb ? "Exporting…" : "Export Database")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }
                        .disabled(isExportingDb || !manager.heartbeatReady)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("SUPPORT")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        // ── Buy Me a Coffee row ──
                        Button {
                            openURL(URL(string: "https://buymeacoffee.com/EduAlexxis")!)
                        } label: {
                            HStack {
                                Image(systemName: "cup.and.saucer.fill")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Buy Me a Coffee")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("Support ByeTunes development")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundColor(Color(.systemGray3))
                            }
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        }

                        // ── Supporters row ──
                        Divider().padding(.leading, 44)

                        HStack(alignment: .top) {
                            Image(systemName: "heart.fill")
                                .font(.body)
                                .foregroundColor(.pink)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Supporters")
                                    .font(.body)
                                    .foregroundColor(.primary)

                                if !supportersLoaded {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(height: 20)
                                } else if supporters.isEmpty {
                                    Text("Be the first to support!")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    // Wrap chips across multiple lines
                                    FlowLayout(spacing: 6) {
                                        ForEach(supporters, id: \.self) { name in
                                            Text(name)
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                                .background(Color(.systemGray6))
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )
                    .task {
                        await fetchSupporters()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("DANGER ZONE")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    Button {
                        showingDeleteAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .font(.body)
                                .foregroundColor(.red)
                                .frame(width: 28)
                            
                            Text("Delete Music Library")
                                .font(.body)
                                .foregroundColor(.red)
                            
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray5), lineWidth: 1)
                        )
                    }
                }

                

                }
                .frame(width: max(proxy.size.width - 40, 0), alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 100)
                }
                .frame(width: proxy.size.width, alignment: .topLeading)
                .clipped()
            }
        }
        .sheet(isPresented: $showingPairingPicker) {
            DocumentPicker(types: [.data, .xml, .propertyList, .item]) { url in
                handlePairingImport(url: url)
            }
        }
        .sheet(isPresented: $showingDownloadFolderPicker) {
            DocumentPicker(types: [.folder], asCopy: false) { url in
                handleDownloadFolderSelection(url: url)
            }
        }
        .sheet(isPresented: $showingDownloaderSettings) {
            NavigationStack {
                DownloaderSettingsScreen(
                    metadataSource: $metadataSource,
                    autofetchMetadata: $autofetchMetadata,
                    fetchLyrics: $fetchLyrics,
                    appleSubscriptionLyrics: $appleSubscriptionLyrics,
                    storeRegion: $storeRegion,
                    appleRichMetadata: $appleRichMetadata,
                    downloadServer: $downloadServer,
                    downloadSearchProvider: $downloadSearchProvider,
                    keepDownloadedSongs: $keepDownloadedSongs,
                    showingDownloadFolderPicker: $showingDownloadFolderPicker,
                    autoDownloadTier: $autoDownloadTier,
                    yoinkifyFormat: $yoinkifyFormat,
                    qobuzFallbackQuality: $qobuzFallbackQuality,
                    tidalFallbackQuality: $tidalFallbackQuality,
                    downloadFolderSubtitle: downloadFolderSubtitle
                )
            }
        }
        .sheet(isPresented: $showingLogViewer) {
            LogViewer()
        }
         .alert("Export Playlist", isPresented: $showingPlaylistNameAlert) {
            TextField("Playlist Name", text: $playlistNameToExport)
            Button("Cancel", role: .cancel) { }
            Button("Export") {
                exportM3UPlaylist(name: playlistNameToExport)
            }
        } message: {
            Text("Enter the exact name of the playlist you want to export.")
        }
        .sheet(isPresented: $showingM3UImportPicker) {
            DocumentPicker(types: [.data, .item]) { url in
                importM3UPlaylist(url: url)
            }
        }
        .sheet(isPresented: $showingM3UExportSheet) {
            LogShareSheet(activityItems: m3uExportURLs)
        }
        .sheet(isPresented: $showingDbExportSheet) {
            LogShareSheet(activityItems: exportedDbURLs)
        }
        .alert("Delete Library?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                manager.deleteMediaLibrary { success in
                    DispatchQueue.main.async {
                        if success {
                            self.showToastMessage(title: "Library Deleted", icon: "trash.circle.fill")
                        } else {
                            self.showToastMessage(title: "Deletion Failed", icon: "exclamationmark.triangle.fill")
                        }
                    }
                }
            }
        } message: {
            Text("This will permanently delete your Music library database and playlists from the device. This action cannot be undone.")
        }
        .onAppear {
            if downloadSearchProvider == DownloadSearchProviderOption.tidal.rawValue {
                downloadSearchProvider = DownloadSearchProviderOption.appleMusic.rawValue
            }
            refreshSnapshots()
        }

        // ── Overlays (inside outer ZStack so they layer correctly) ──

        if isFixingArtwork || isRebuildingAlbumArtwork {
            artworkFixPopup
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }

        if isSnapshotBusy && (isCreatingSnapshot || isRestoringSnapshot) {
            snapshotProgressPopup
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }

        if showToast {
            HStack(spacing: 12) {
                Image(systemName: toastIcon)
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)

                Text(toastTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding(.horizontal, 24)
            .padding(.bottom, 100)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }

        } // ← outer ZStack
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isFixingArtwork)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isRebuildingAlbumArtwork)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isSnapshotBusy)
        .animation(.spring(), value: showToast)
        }
    } // body

    // MARK: - Supporters

    private func fetchSupporters() async {
        guard !supportersLoaded || supporters.isEmpty else { return }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://raw.githubusercontent.com/EduAlexxis/EduAlexxis-Altstore-Repo/main/supporters.json?t=\(timestamp)") else { return }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Response: Decodable { let supporters: [String] }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            await MainActor.run {
                supporters = decoded.supporters
                supportersLoaded = true
            }
        } catch {
            print("Failed to fetch supporters: \(error)")
            await MainActor.run {
                supportersLoaded = true
            }
        }
    }

    private var isExperimentalArtworkRefreshActive: Bool {
        isRebuildingAlbumArtwork && !isFixingArtwork
    }

    private var artworkFixPopup: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 58, height: 58)

                    Image(systemName: isExperimentalArtworkRefreshActive ? "wand.and.stars" : "photo.on.rectangle.angled")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 6) {
                    Text(isExperimentalArtworkRefreshActive ? "Refreshing Metadata & Artwork" : "Fixing Artwork")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("Hang tight, this could take some time.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    if let artworkFixProgress {
                        ProgressView(value: artworkFixProgress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                    }

                    Text(artworkFixMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity)
                }

                Button {
                    manager.artworkRepairCancelled = true
                    isRebuildingAlbumArtwork = false
                    isFixingArtwork = false
                    artworkFixMessage = "Cancelling..."
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.systemGray5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 28)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var snapshotProgressPopup: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 58, height: 58)

                    Image(systemName: isRestoringSnapshot ? "arrow.counterclockwise.circle.fill" : "externaldrive.badge.plus")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 6) {
                    Text(snapshotProgressTitle)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(isCreatingSnapshot && fullBackupSnapshots ? "Hang tight, full backups can take some time." : "Hang tight, this could take some time.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    if let snapshotProgress {
                        ProgressView(value: snapshotProgress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                    }

                    Text(snapshotProgressMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.systemGray5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
            .padding(.horizontal, 28)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func exportDatabase() {
        isExportingDb = true

        let tmp = FileManager.default.temporaryDirectory
        let files: [(remote: String, local: URL)] = [
            ("/iTunes_Control/iTunes/MediaLibrary.sqlitedb",
             tmp.appendingPathComponent("MediaLibrary.sqlitedb")),
            ("/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm",
             tmp.appendingPathComponent("MediaLibrary.sqlitedb-shm")),
            ("/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal",
             tmp.appendingPathComponent("MediaLibrary.sqlitedb-wal")),
            ("/iTunes_Control/Ringtones/Ringtones.plist",
             tmp.appendingPathComponent("Ringtones.plist"))
        ]

        var downloaded: [URL] = []

        func downloadNext(_ index: Int) {
            guard index < files.count else {
                DispatchQueue.main.async {
                    self.isExportingDb = false
                    if downloaded.isEmpty {
                        self.showToastMessage(title: "Export Failed", icon: "xmark.circle.fill")
                    } else {
                        self.exportedDbURLs = downloaded
                        self.showingDbExportSheet = true
                    }
                }
                return
            }

            let file = files[index]
            manager.downloadFileFromDevice(remotePath: file.remote, localURL: file.local) { success in
                if success {
                    downloaded.append(file.local)
                }
                downloadNext(index + 1)
            }
        }

        downloadNext(0)
    }

    private func createSnapshotBackup() {
        isSnapshotBusy = true
        isCreatingSnapshot = true
        isRestoringSnapshot = false
        updateSnapshotProgress(title: fullBackupSnapshots ? "Creating Full Backup" : "Creating Backup", message: "Preparing backup...", progress: nil)
        manager.createDatabaseSnapshot { message, progress in
            DispatchQueue.main.async {
                self.updateSnapshotProgress(title: self.fullBackupSnapshots ? "Creating Full Backup" : "Creating Backup", message: message, progress: progress)
            }
        } completion: { success, message in
            DispatchQueue.main.async {
                self.isSnapshotBusy = false
                self.isCreatingSnapshot = false
                self.updateSnapshotProgress(title: self.fullBackupSnapshots ? "Creating Full Backup" : "Creating Backup", message: message, progress: success ? 1 : nil)
                self.showToastMessage(
                    title: success ? message : "Backup Failed: \(message)",
                    icon: success ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                self.refreshSnapshots()
            }
        }
    }
    
    private func restoreSnapshotBackup() {
        isSnapshotBusy = true
        isCreatingSnapshot = false
        isRestoringSnapshot = true
        updateSnapshotProgress(title: "Restoring Backup", message: "Preparing restore...", progress: nil)
        manager.restoreLatestDatabaseSnapshot { message, progress in
            DispatchQueue.main.async {
                self.updateSnapshotProgress(title: "Restoring Backup", message: message, progress: progress)
            }
        } completion: { success, message in
            DispatchQueue.main.async {
                self.isSnapshotBusy = false
                self.isRestoringSnapshot = false
                self.updateSnapshotProgress(title: "Restoring Backup", message: message, progress: success ? 1 : nil)
                self.showToastMessage(
                    title: success ? message : "Restore Failed: \(message)",
                    icon: success ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill"
                )
                self.refreshSnapshots()
            }
        }
    }
    
    private func restoreSnapshot(named folderName: String) {
        isSnapshotBusy = true
        isCreatingSnapshot = false
        isRestoringSnapshot = true
        updateSnapshotProgress(title: "Restoring Backup", message: "Preparing restore...", progress: nil)
        manager.restoreDatabaseSnapshot(named: folderName) { message, progress in
            DispatchQueue.main.async {
                self.updateSnapshotProgress(title: "Restoring Backup", message: message, progress: progress)
            }
        } completion: { success, message in
            DispatchQueue.main.async {
                self.isSnapshotBusy = false
                self.isRestoringSnapshot = false
                self.updateSnapshotProgress(title: "Restoring Backup", message: message, progress: success ? 1 : nil)
                self.showToastMessage(
                    title: success ? message : "Restore Failed: \(message)",
                    icon: success ? "arrow.counterclockwise.circle.fill" : "xmark.circle.fill"
                )
            }
        }
    }

    private func updateSnapshotProgress(title: String, message: String, progress: Double?) {
        snapshotProgressTitle = title
        snapshotProgressMessage = message.isEmpty ? "Working..." : message
        snapshotProgress = progress.map { min(max($0, 0), 1) }
        status = snapshotProgressMessage
    }
    
    private func deleteSnapshot(named folderName: String) {
        isSnapshotBusy = true
        isCreatingSnapshot = false
        isRestoringSnapshot = false
        manager.deleteDatabaseSnapshot(named: folderName) { success, message in
            DispatchQueue.main.async {
                self.isSnapshotBusy = false
                self.showToastMessage(
                    title: success ? message : "Delete Failed: \(message)",
                    icon: success ? "trash.circle.fill" : "xmark.circle.fill"
                )
                self.refreshSnapshots()
            }
        }
    }
    
    private func refreshSnapshots() {
        manager.fetchDatabaseSnapshots { list in
            DispatchQueue.main.async {
                self.snapshots = list
            }
        }
    }

    private func checkForSettingsUpdate() {
        isCheckingForUpdate = true
        Task {
            do {
                let update = try await AppUpdateChecker.checkForUpdate()
                await MainActor.run {
                    self.isCheckingForUpdate = false
                    self.settingsUpdate = update
                    if let update {
                        self.showToastMessage(title: "ByeTunes \(update.version) is available", icon: "arrow.down.circle.fill")
                    } else {
                        self.showToastMessage(title: "ByeTunes is up to date", icon: "checkmark.circle.fill")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isCheckingForUpdate = false
                    self.showToastMessage(title: "Update Check Failed", icon: "xmark.circle.fill")
                }
                Logger.shared.log("[Update] Settings version check failed: \(error.localizedDescription)")
            }
        }
    }

    private func fixArtwork() {
        isFixingArtwork = true
        updateArtworkFixProgress("Fixing artwork...")

        manager.repairIOS26ArtworkColors { message in
            DispatchQueue.main.async {
                self.updateArtworkFixProgress(message)
            }
        } completion: { success, message in
            DispatchQueue.main.async {
                self.isFixingArtwork = false
                // Silently dismiss if user already cancelled via the Cancel button
                guard !message.lowercased().contains("cancel") else { return }
                self.updateArtworkFixProgress(message)
                self.showToastMessage(
                    title: success ? message : "Artwork Fix Failed: \(message)",
                    icon: success ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
            }
        }
    }

    private func rebuildAlbumArtworkExperimental() {
        isRebuildingAlbumArtwork = true
        updateArtworkFixProgress("Running advanced artwork and metadata fix...")

        manager.repairExperimentalAlbumArtworkPointers { message in
            DispatchQueue.main.async {
                self.updateArtworkFixProgress(message)
            }
        } completion: { success, message in
            DispatchQueue.main.async {
                self.isRebuildingAlbumArtwork = false
                // Silently dismiss if user already cancelled via the Cancel button
                guard !message.lowercased().contains("cancel") else { return }
                self.updateArtworkFixProgress(message)
                self.showToastMessage(
                    title: success ? message : "Advanced Artwork & Metadata Fix Failed: \(message)",
                    icon: success ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
            }
        }
    }

    private func updateArtworkFixProgress(_ message: String) {
        status = message
        artworkFixMessage = message.isEmpty ? "Fixing artwork..." : message
        artworkFixProgress = parsedArtworkFixProgress(from: message)
    }

    private func parsedArtworkFixProgress(from message: String) -> Double? {
        guard let range = message.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) else {
            return nil
        }

        let parts = message[range].split(separator: "/")
        guard parts.count == 2,
              let current = Double(parts[0]),
              let total = Double(parts[1]),
              total > 0 else {
            return nil
        }

        return min(max(current / total, 0), 1)
    }
    
    private func formatSnapshotDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
    
    private func showToastMessage(title: String, icon: String) {
        withAnimation(.spring()) {
            self.toastTitle = title
            self.toastIcon = icon
            self.showToast = true
        }
        
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeOut(duration: 0.5)) {
                self.showToast = false
            }
        }
    }
    
    func handlePairingImport(url: URL?) {
        guard let url = url else { return }
        
        do {
            try manager.importPairingFile(from: url)
            status = "\(manager.expectedPairingFileTitle) imported"
            
            manager.startHeartbeat()
        } catch {
            status = error.localizedDescription
        }
    }

    private var downloadFolderSubtitle: String {
        let directory = SongMetadata.persistentDownloadsDirectory()
        if SongMetadata.customPersistentDownloadsDirectory() != nil {
            return directory.lastPathComponent
        }
        return "App Folder"
    }

    private func handleDownloadFolderSelection(url: URL?) {
        guard let url else { return }

        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "downloadedSongsFolderBookmark")
            showToastMessage(title: "Download Folder Updated", icon: "folder.badge.checkmark")
        } catch {
            showToastMessage(title: "Folder Selection Failed", icon: "exclamationmark.triangle.fill")
        }
    }
}

private struct DownloaderSettingsScreen: View {
    @StateObject private var backendHealthStore = BackendHealthStore.shared

    @Binding var metadataSource: String
    @Binding var autofetchMetadata: Bool
    @Binding var fetchLyrics: Bool
    @Binding var appleSubscriptionLyrics: Bool
    @Binding var storeRegion: String
    @Binding var appleRichMetadata: Bool
    @Binding var downloadServer: String
    @Binding var downloadSearchProvider: String
    @Binding var keepDownloadedSongs: Bool
    @Binding var showingDownloadFolderPicker: Bool
    @Binding var autoDownloadTier: String
    @Binding var yoinkifyFormat: String
    @Binding var qobuzFallbackQuality: String
    @Binding var tidalFallbackQuality: String

    let downloadFolderSubtitle: String

    private var selectedServer: DownloaderServerPreference { .auto }

    private var relevantHealthRecords: [BackendHealthRecord] {
        let all = backendHealthStore.reportItems()
        switch selectedServer {
        case .auto:
            return all.filter { $0.label == "ByeTunes API" || $0.label == "Deezer API (Zarz)" }
        case .byeTunesAPI:
            return all.filter { $0.label == "ByeTunes API" || $0.label == "ByeTunes API (MP3 Fallback)" }
        case .yoinkify:
            return all.filter { $0.label == "Yoinkify" }
        case .qobuz:
            return all.filter { $0.label == "Qobuz API (Zarz)" }
        case .appleMusicAPI:
            return all.filter { $0.label == "Apple Music API (app2)" || $0.label == "Apple Music API (app)" }
        case .deezerAPI:
            return all.filter { $0.label == "Deezer API (Zarz)" }
        case .tidalAPI:
            return all.filter { $0.label == "Tidal API (tid2)" || $0.label == "Tidal API (tid)" }
        case .pandoraAPI:
            return all.filter { $0.label == "Pandora API (Zarz)" }
        case .amazonAPI:
            return all.filter { $0.label == "Amazon Music API (Zarz)" }
        case .soundCloudAPI:
            return all.filter { $0.label == "SoundCloud API (Cobalt)" }
        case .youtubeAPI:
            return all.filter { $0.label == "YouTube API (Cobalt)" }
        case .hifiOne:
            return all.filter { $0.label == "HiFi One" }
        case .hifiTwo:
            return all.filter { $0.label == "HiFi Two" }
        }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("METADATA")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        serverPickerRow(
                            icon: "wand.and.stars",
                            title: "Import Metadata Source",
                            subtitle: "Choose how imported songs get matched and enriched",
                            selection: $metadataSource,
                            options: MetadataSourceOption.allCases
                        )

                        if metadataSource != "apple" {
                            Divider().padding(.leading, 56)

                            Toggle(isOn: $appleRichMetadata) {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .font(.body)
                                        .foregroundColor(.orange)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Rich Apple Metadata")
                                            .font(.body)
                                        Text("Fetch Store IDs, XID, and copyright details")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                        }

                        if metadataSource == "itunes" || metadataSource == "deezer" || metadataSource == "apple" {
                            Divider().padding(.leading, 56)

                            Toggle(isOn: $autofetchMetadata) {
                                HStack {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Autofetch")
                                            .font(.body)
                                        Text("Automatically fetch metadata on import")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                        }

                        if !appleSubscriptionLyrics {
                            Divider().padding(.leading, 56)

                            Toggle(isOn: $fetchLyrics) {
                                HStack {
                                    Image(systemName: "quote.bubble.fill")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Fetch Lyrics")
                                            .font(.body)
                                        Text("Automatically fetch lyrics from LRCLIB, then Musixmatch, then NetEase")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                        }

                        Divider().padding(.leading, 56)

                        Toggle(isOn: $appleSubscriptionLyrics) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Apple Music Subscription Lyrics")
                                        .font(.body)
                                    Text("Use synced Apple Music lyrics for subscribers (internet required)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)

                        if metadataSource == "itunes" {
                            Divider().padding(.leading, 56)

                            serverPickerRow(
                                icon: "globe",
                                title: "Store Region",
                                subtitle: "Select the storefront used for iTunes metadata lookups",
                                selection: $storeRegion,
                                options: MetadataStoreRegionOption.allCases
                            )
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )

                    Text("DOWNLOADS")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        serverPickerRow(
                            icon: "magnifyingglass",
                            title: "Search Source",
                            subtitle: "Choose where the Download tab searches for results",
                            selection: $downloadSearchProvider,
                            options: DownloadSearchProviderOption.allCases
                        )

                        Divider().padding(.leading, 56)

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: backendHealthStore.isRefreshing ? "arrow.triangle.2.circlepath.circle.fill" : "waveform.path.ecg")
                                .font(.body)
                                .foregroundColor(.primary)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Server Health")
                                    .font(.body)
                                Text(serverHealthSummary)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button {
                                backendHealthStore.refreshHealth(for: selectedServer, force: true)
                            } label: {
                                if backendHealthStore.isRefreshing {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)

                        Divider().padding(.leading, 56)

                        Toggle(isOn: $keepDownloadedSongs) {
                            HStack {
                                Image(systemName: "square.and.arrow.down.on.square")
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Keep Downloaded Songs")
                                        .font(.body)
                                    Text("Store downloaded tracks in app Documents folder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .accentColor))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)

                        if keepDownloadedSongs {
                            Divider().padding(.leading, 56)

                            Button {
                                showingDownloadFolderPicker = true
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Download Folder")
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text(downloadFolderSubtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(Color(.systemGray3))
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )

                    Text("DOWNLOAD FORMAT")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        serverPickerRow(
                            icon: "sparkles.rectangle.stack",
                            title: "Output Format",
                            subtitle: "ByeTunes is used first, with Deezer as the automatic fallback",
                            selection: $yoinkifyFormat,
                            options: DownloaderYoinkifyFormatOption.allCases
                        )
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray5), lineWidth: 1)
                    )

                    }
                    .frame(width: max(proxy.size.width - 40, 0), alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(width: proxy.size.width, alignment: .topLeading)
                .clipped()
            }
        }
        .navigationTitle("Metadata & Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            downloadServer = DownloaderServerPreference.auto.rawValue
            backendHealthStore.refreshHealth(for: selectedServer)
        }
    }

    private func serverPickerRow<Option: Identifiable & CustomStringConvertible>(
        icon: String,
        title: String,
        subtitle: String,
        selection: Binding<String>,
        options: [Option]
    ) -> some View where Option: RawRepresentable, Option.RawValue == String {
        HStack {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.description).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
    }

    private var serverHealthSummary: String {
        if backendHealthStore.isRefreshing && relevantHealthRecords.allSatisfy({ $0.lastUpdatedAt == .distantPast }) {
            return "Checking ByeTunes and Deezer..."
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short

        if selectedServer == .auto || selectedServer == .qobuz {
            let reachable = relevantHealthRecords.filter { $0.lastOutcome == "Healthy" }.count
            let checked = relevantHealthRecords.filter { $0.lastUpdatedAt != .distantPast }.count

            if checked == 0 {
                return "Not checked yet."
            }

            if let lastUsed = backendHealthStore.lastUsedLabel {
                return "\(reachable) of \(relevantHealthRecords.count) reachable. Last used: \(lastUsed)."
            }

            return "\(reachable) of \(relevantHealthRecords.count) reachable."
        }

        guard let record = relevantHealthRecords.first else {
            return "Not checked yet."
        }

        switch record.lastOutcome {
        case "Healthy":
            let relative = record.lastUpdatedAt == .distantPast ? "not checked yet" : formatter.localizedString(for: record.lastUpdatedAt, relativeTo: Date())
            return "Reachable. Checked \(relative)."
        case "Failing":
            let relative = record.lastUpdatedAt == .distantPast ? "just now" : formatter.localizedString(for: record.lastUpdatedAt, relativeTo: Date())
            let reason = record.lastError?.isEmpty == false ? record.lastError! : "request failed"
            return "Currently failing. Checked \(relative). \(reason)"
        default:
            return "Not checked yet."
        }
    }
}

private enum MetadataSourceOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case local
    case itunes
    case deezer
    case apple

    var id: String { rawValue }

    var description: String {
        switch self {
        case .local: return "Local Files"
        case .itunes: return "iTunes API"
        case .deezer: return "Deezer API"
        case .apple: return "Apple Music"
        }
    }
}

private enum DownloadSearchProviderOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case appleMusic
    case spotify
    case tidal
    case metadata

    static var allCases: [DownloadSearchProviderOption] {
        [.appleMusic, .spotify, .metadata]
    }

    var id: String { rawValue }

    var description: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .tidal: return "Tidal"
        case .metadata: return "iTunes + Deezer"
        }
    }
}

private enum MetadataStoreRegionOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case us = "US"
    case mx = "MX"
    case es = "ES"
    case gb = "GB"
    case jp = "JP"
    case br = "BR"
    case de = "DE"
    case fr = "FR"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .us: return "US"
        case .mx: return "MX"
        case .es: return "ES"
        case .gb: return "GB"
        case .jp: return "JP"
        case .br: return "BR"
        case .de: return "DE"
        case .fr: return "FR"
        }
    }
}

private enum DownloaderAutoTierOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case low
    case medium
    case high

    var id: String { rawValue }

    var description: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

private enum DownloaderYoinkifyFormatOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case mp3
    case flac
    case alac

    var id: String { rawValue }
    var description: String { rawValue.uppercased() }
}

private enum DownloaderTidalQualityOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case low = "LOW"
    case high = "HIGH"
    case lossless = "LOSSLESS"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .low: return "Low"
        case .high: return "High"
        case .lossless: return "Lossless"
        }
    }
}

private enum DownloaderQobuzQualityOption: String, CaseIterable, Identifiable, CustomStringConvertible {
    case lossless = "6"
    case hiRes = "7"
    case hiResMax = "27"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .lossless: return "Lossless"
        case .hiRes: return "Hi-Res"
        case .hiResMax: return "Max Hi-Res"
        }
    }
}

// MARK: - FlowLayout
// A simple left-to-right wrapping layout for supporter chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let containerWidth = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > containerWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        y += rowHeight
        return CGSize(width: containerWidth, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
    private func exportM3UPlaylist(name: String) {
    guard !name.isEmpty else { return }
    isProcessingM3U = true

    let tmp = FileManager.default.temporaryDirectory
    let localDBURL = tmp.appendingPathComponent("TempExportDB-\(UUID().uuidString).sqlitedb")

    // 1. Pull the live database from the device over the tunnel
    manager.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb", localURL: localDBURL) { success in
        guard success, let dbData = try? Data(contentsOf: localDBURL) else {
            DispatchQueue.main.async {
                self.isProcessingM3U = false
                self.showToastMessage(title: "Failed to read database", icon: "xmark.circle.fill")
            }
            return
        }

        // 2. Feed it into our new Exporter logic
        do {
            let exportURL = tmp.appendingPathComponent("\(name).m3u8")
            try PlaylistExporter.exportPlaylist(existingDbData: dbData, playlistName: name, toFileURL: exportURL)

            DispatchQueue.main.async {
                self.isProcessingM3U = false
                self.m3uExportURLs = [exportURL]
                self.showingM3UExportSheet = true // Triggers the iOS share sheet to save the file
            }
        } catch {
            DispatchQueue.main.async {
                self.isProcessingM3U = false
                self.showToastMessage(title: "Export Failed: \(error.localizedDescription)", icon: "xmark.circle.fill")
            }
        }
    }
}

private func importM3UPlaylist(url: URL?) {
    guard let url = url else { return }
    isProcessingM3U = true

    let tmp = FileManager.default.temporaryDirectory
    let localDBURL = tmp.appendingPathComponent("TempImportDB-\(UUID().uuidString).sqlitedb")

    // 1. Pull the live database to get the newly injected song signatures
    manager.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb", localURL: localDBURL) { success in
        guard success, let dbData = try? Data(contentsOf: localDBURL) else {
            DispatchQueue.main.async {
                self.isProcessingM3U = false
                self.showToastMessage(title: "Failed to read database", icon: "xmark.circle.fill")
            }
            return
        }

        // 2. Re-assemble the playlist in the local DB copy
        do {
            let result = try PlaylistExporter.importPlaylist(existingDbData: dbData, fromFileURL: url, playlistName: nil)

            let updatedDBURL = tmp.appendingPathComponent("UpdatedMediaLibrary-\(UUID().uuidString).sqlitedb")
            try result.updatedDbData.write(to: updatedDBURL)

            // 3. Push the modified database back to the device
            // ⚠️ CHECK DEVICEMANAGER.SWIFT: Replace 'uploadFileToDevice' with the actual function name ByeTunes uses.
            manager.uploadFileToDevice(localURL: updatedDBURL, remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { pushSuccess in
                DispatchQueue.main.async {
                    self.isProcessingM3U = false
                    if pushSuccess {
                        self.showToastMessage(title: "Imported \(result.matchedCount) tracks", icon: "checkmark.circle.fill")
                    } else {
                        self.showToastMessage(title: "Failed to push database back", icon: "xmark.circle.fill")
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isProcessingM3U = false
                self.showToastMessage(title: "Import Failed: \(error.localizedDescription)", icon: "xmark.circle.fill")
            }
        }
    }
}
}
