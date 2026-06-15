import Foundation
import Darwin
import Combine
import UIKit
import CommonCrypto
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)


typealias IdevicePairingFile = OpaquePointer
typealias IdeviceProviderHandle = OpaquePointer
typealias HeartbeatClientHandle = OpaquePointer
typealias AfcClientHandle = OpaquePointer
typealias AfcFileHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer
typealias NotificationProxyClientHandle = OpaquePointer
typealias CoreDeviceProxyHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias ReadWriteOpaqueHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias AppServiceHandle = OpaquePointer
typealias RpPairingFileHandle = OpaquePointer

typealias IdeviceErrorCode = UnsafeMutablePointer<IdeviceFfiError>?
typealias SnapshotProgressHandler = (String, Double?) -> Void

let IdeviceSuccess: IdeviceErrorCode = nil

enum PairingFileImportError: LocalizedError {
    case invalidFileType(expected: String)

    var errorDescription: String? {
        switch self {
        case .invalidFileType(let expected):
            return "That file is not a valid \(expected)."
        }
    }
}


private let BUILD_VERSION = "v2.3"
private let DEVICE_HOST = "10.7.0.1"
private let RP_PAIRING_PORT: UInt16 = 49152

class DeviceManager: ObservableObject {
    struct DatabaseSnapshotInfo: Identifiable {
        var id: String { folderName }
        let folderName: String
        let createdAt: Date
        let songCount: Int
    }

    struct ExportableSongInfo: Identifiable, Hashable {
        var id: String { remoteFilename }
        let itemPid: Int64
        let remoteFilename: String
        let title: String
        let artist: String
        let album: String
        let genre: String
        let year: Int
        let durationMs: Int
        let fileSize: Int
        let trackNumber: Int?
        let lyrics: String?
        let explicitRating: Int
        let fileExtension: String
        let artworkRelativePath: String?

        var suggestedFilename: String {
            let ext = fileExtension.isEmpty ? "mp3" : fileExtension
            return "\(DeviceManager.sanitizedExportFilenameBase("\(artist) - \(title)")).\(ext)"
        }
    }

    private struct ArtworkRepairCandidate {
        let itemPid: Int64
        let albumPid: Int64
        let storeItemId: Int64
        let title: String
        let artist: String
        let album: String
        let artworkToken: String
        let relativePath: String
    }

    private struct AlbumArtworkPointerCandidate {
        let albumPid: Int64
        let token: String
        let sourceTypes: [Int]
        let albumName: String
    }

    private struct ExperimentalAppleMetadataRepair {
        let itemPid: Int64
        let albumPid: Int64
        let artworkToken: String
        let relativePath: String
        let title: String
        let artist: String
        let album: String
        let year: Int
        let trackNumber: Int
        let trackCount: Int
        let discNumber: Int
        let discCount: Int
        let durationMs: Int
        let explicitRating: Int
        let copyright: String
        let storeItemId: Int64
        let artistId: Int64
        let composerId: Int64
        let genreStoreId: Int64
        let albumStoreId: Int64
        let storefrontId: Int64
        let storeXid: String
        let storeFlavor: String
        let releaseDate: Int
        let subscriptionStoreItemId: Int64
        let masteredForItunes: Int
        let hlsAssetTraits: Int
        let colorAnalysis: String
        let artworkData: Data?
    }

    @Published var heartbeatReady: Bool = false
    @Published var connectionStatus: String = "Disconnected"
    @Published private(set) var hasValidExpectedPairingFile: Bool = false
    var provider: IdeviceProviderHandle?
    var rpAdapter: AdapterHandle?
    var rpHandshake: RsdHandshakeHandle?
    var heartbeatThread: Thread?
    private var heartbeatSessionID: UInt64 = 0
    nonisolated(unsafe) var artworkRepairCancelled: Bool = false
    private var autoReconnectTimer: DispatchSourceTimer?
    private var hasCompletedInitialAutoConnect = false
    private var lastHeartbeatAttemptStartedAt: Date = .distantPast
    private let autoReconnectCheckInterval: TimeInterval = 2
    private let staleHeartbeatAttemptInterval: TimeInterval = 6
    
    private var lastLoggedStatus: [String: String] = [:]
    
    private func logOnce(_ message: String, key: String) {
        objc_sync_enter(self)
        let changed = lastLoggedStatus[key] != message
        if changed {
            lastLoggedStatus[key] = message
        }
        objc_sync_exit(self)
        
        if changed {
            Logger.shared.log(message)
        }
    }
    
    static var shared = DeviceManager()
    
    
    static let appGroupID = "group.com.edualexxis.MusicManager"

    private static func sanitizedExportFilenameBase(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.isEmpty ? "Exported Song" : collapsed
    }
    
    var pairingFile: URL {
        regularPairingFile
    }

    var regularPairingFile: URL {
        let base: URL
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            base = containerURL
        } else {
            base = URL.documentsDirectory
        }
        return base.appendingPathComponent("pairing file").appendingPathComponent("pairingFile.plist")
    }

    var rpPairingFile: URL {
        regularPairingFile.deletingLastPathComponent().appendingPathComponent("rpPairingFile.plist")
    }

    private var expectedPairingFile: URL {
        requiresRPPairingTunnel ? rpPairingFile : regularPairingFile
    }
    
    
    static var sharedContainerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private var requiresRPPairingTunnel: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion > 26 { return true }
        return version.majorVersion == 26 && version.minorVersion >= 4
    }

    private var connectionModeDescription: String {
        requiresRPPairingTunnel ? "RPPairing tunnel" : "lockdown pairing file"
    }

    var expectedPairingFileDescription: String {
        requiresRPPairingTunnel ? "RP pairing file" : "pairing file"
    }

    var expectedPairingFileTitle: String {
        requiresRPPairingTunnel ? "RP Pairing File" : "Pairing File"
    }

    var needsRPPairingFileUpgrade: Bool {
        requiresRPPairingTunnel && !hasValidExpectedPairingFile
    }

    var shouldPromptForRPPairingUpgrade: Bool {
        requiresRPPairingTunnel && !hasValidExpectedPairingFile && validateLockdownPairingFile(at: regularPairingFile)
    }

    var supportsIOS26ArtworkRepair: Bool {
        requiresRPPairingTunnel
    }

    private var hasActiveTransport: Bool {
        if requiresRPPairingTunnel {
            return rpAdapter != nil && rpHandshake != nil
        }
        return provider != nil
    }
    
    private var snapshotsDirectoryURL: URL {
        let base = Self.sharedContainerURL ?? URL.documentsDirectory
        let hidden = base.appendingPathComponent(".db_snapshots", isDirectory: true)
        let legacy = base.appendingPathComponent("db_snapshots", isDirectory: true)
        migrateLegacySnapshotsDirectory(from: legacy, to: hidden)
        return hidden
    }
    
    private let snapshotMusicManifestName = "music_files.txt"
    private let snapshotArtworkManifestName = "artwork_paths.txt"
    private let snapshotArtworkDirectory = "Artwork/Originals"
    private let snapshotFullBackupDirectory = ".iTunesFullBackup"
    
    private init() {
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] BUILD VERSION: \(BUILD_VERSION)")
        Logger.shared.log("===========================================")
        Logger.shared.log("[DeviceManager] Initializing...")
        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("idevice-logs.txt").path
        let cString = strdup(logPath)
        defer { free(cString) }
        idevice_init_logger(Info, Disabled, cString)
        
        let folderPath = self.regularPairingFile.deletingLastPathComponent()
        do {
            if !FileManager.default.fileExists(atPath: folderPath.path) {
                try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: true)
                Logger.shared.log("[DeviceManager] Created pairing file directory at: \(folderPath.path)")
            }
        } catch {
            Logger.shared.log("[DeviceManager] Error creating pairing directory: \(error)")
        }
        refreshExpectedPairingFileState()
        installAutoReconnectWatcher()
    }

    private func installAutoReconnectWatcher() {
        guard autoReconnectTimer == nil else { return }

        Logger.shared.log("[DeviceManager] Installing auto-reconnect watcher")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + autoReconnectCheckInterval, repeating: autoReconnectCheckInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard UIApplication.shared.applicationState == .active else { return }

            self.refreshExpectedPairingFileState()
            guard self.hasValidExpectedPairingFile else {
                self.logOnce("[DeviceManager] Auto-reconnect skipped: pairing file is not valid", key: "auto_reconnect")
                return
            }

            let connectingIsStale =
                self.connectionStatus == "Connecting..."
                && Date().timeIntervalSince(self.lastHeartbeatAttemptStartedAt) >= self.staleHeartbeatAttemptInterval

            guard self.connectionStatus != "Connecting..." || connectingIsStale else {
                self.logOnce("[DeviceManager] Auto-reconnect skipped: already connecting", key: "auto_reconnect")
                return
            }

            if connectingIsStale {
                self.logOnce("[DeviceManager] Auto-reconnect detected stale connecting state; forcing refresh", key: "auto_reconnect")
            }

            let needsReconnect = !self.heartbeatReady || !self.hasActiveTransport || !self.canStillReachDevice()
            guard needsReconnect else { return }

            self.logOnce("[DeviceManager] Auto-reconnect triggering forced heartbeat refresh", key: "auto_reconnect")
            self.startHeartbeat(forceReconnect: true)
        }
        timer.resume()
        autoReconnectTimer = timer
    }

    private func stopAutoReconnectWatcher() {
        guard let timer = autoReconnectTimer else { return }
        timer.setEventHandler {}
        timer.cancel()
        autoReconnectTimer = nil
        Logger.shared.log("[DeviceManager] Auto-reconnect watcher stopped after initial connection")
    }

    private func migrateLegacySnapshotsDirectory(from legacy: URL, to hidden: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }

        do {
            if !fm.fileExists(atPath: hidden.path) {
                try fm.moveItem(at: legacy, to: hidden)
                Logger.shared.log("[Backup] Migrated snapshots folder to hidden storage")
                return
            }

            let entries = try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for entry in entries {
                let destination = hidden.appendingPathComponent(entry.lastPathComponent, isDirectory: entry.hasDirectoryPath)
                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }
                try fm.moveItem(at: entry, to: destination)
            }
            try fm.removeItem(at: legacy)
            Logger.shared.log("[Backup] Merged legacy snapshots into hidden storage")
        } catch {
            Logger.shared.log("[Backup] Failed to migrate legacy snapshots folder: \(error)")
        }
    }

    
    private func resetConnectionHandles() {
        heartbeatSessionID &+= 1
        if let oldProvider = provider {
            idevice_provider_free(oldProvider)
            provider = nil
        }
        if let oldHandshake = rpHandshake {
            rsd_handshake_free(oldHandshake)
            rpHandshake = nil
        }
        if let oldAdapter = rpAdapter {
            adapter_close(oldAdapter)
            adapter_free(oldAdapter)
            rpAdapter = nil
        }
    }

    private func canStillReachDevice() -> Bool {
        guard hasActiveTransport else { return false }
        var probeClient: HeartbeatClientHandle?
        let err = connectHeartbeatClient(&probeClient)
        guard err == IdeviceSuccess, let probeClient else {
            return false
        }
        heartbeat_client_free(probeClient)
        return true
    }

    private func makeSocketAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        inet_pton(AF_INET, DEVICE_HOST, &addr.sin_addr)
        return addr
    }

    func refreshExpectedPairingFileState() {
        hasValidExpectedPairingFile = validateExpectedPairingFile()
    }

    func importPairingFile(from url: URL) throws {
        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let directory = expectedPairingFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: expectedPairingFile.path) {
            try FileManager.default.removeItem(at: expectedPairingFile)
        }
        try FileManager.default.copyItem(at: url, to: expectedPairingFile)

        refreshExpectedPairingFileState()
        guard hasValidExpectedPairingFile else {
            try? FileManager.default.removeItem(at: expectedPairingFile)
            refreshExpectedPairingFileState()
            throw PairingFileImportError.invalidFileType(expected: expectedPairingFileTitle)
        }
    }

    private func validateExpectedPairingFile() -> Bool {
        let file = expectedPairingFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            return false
        }

        if requiresRPPairingTunnel {
            return validateRPPairingFile(at: file)
        }

        return validateLockdownPairingFile(at: file)
    }

    private func validateLockdownPairingFile(at file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return false
        }

        var pairingPtr: IdevicePairingFile?
        let readErr = idevice_pairing_file_read(file.path, &pairingPtr)
        guard readErr == IdeviceSuccess, let pairingHandle = pairingPtr else {
            return false
        }
        idevice_pairing_file_free(pairingHandle)
        return true
    }

    private func validateRPPairingFile(at file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return false
        }

        var rpPairingPtr: RpPairingFileHandle?
        let readErr = rp_pairing_file_read(file.path, &rpPairingPtr)
        guard readErr == IdeviceSuccess, let rpPairingHandle = rpPairingPtr else {
            return false
        }
        rp_pairing_file_free(rpPairingHandle)
        return true
    }

    @discardableResult
    private func connectHeartbeatClient(_ client: inout HeartbeatClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            return heartbeat_connect_rsd(rpAdapter, rpHandshake, &client)
        }
        return heartbeat_connect(provider, &client)
    }

    @discardableResult
    private func connectLockdownClient(_ client: inout LockdowndClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            return lockdownd_connect_rsd(rpAdapter, rpHandshake, &client)
        }
        return lockdownd_connect(provider, &client)
    }

    @discardableResult
    private func connectNotificationProxyClient(_ client: inout NotificationProxyClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            return notification_proxy_connect_rsd(rpAdapter, rpHandshake, &client)
        }
        return notification_proxy_connect(provider, &client)
    }

    @discardableResult
    private func connectAfcClient(_ client: inout AfcClientHandle?) -> IdeviceErrorCode {
        if requiresRPPairingTunnel, let rpAdapter, let rpHandshake {
            var lastError: IdeviceErrorCode = IdeviceSuccess
            for attempt in 0..<10 {
                lastError = afc_client_connect_rsd(rpAdapter, rpHandshake, &client)
                if lastError == IdeviceSuccess && client != nil {
                    return lastError
                }
                if attempt < 9 {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            return lastError
        }
        return afc_client_connect(provider, &client)
    }

    private func establishRPPairingTunnel() -> Bool {
        var rpPairingPtr: RpPairingFileHandle?
        let readErr = rp_pairing_file_read(rpPairingFile.path, &rpPairingPtr)
        guard readErr == IdeviceSuccess, let rpPairingHandle = rpPairingPtr else {
            self.logOnce("[DeviceManager] ERROR: Failed to read RPPairing file. Err: \(String(describing: readErr))", key: "connection_status")
            return false
        }
        defer { rp_pairing_file_free(rpPairingHandle) }

        var addr = makeSocketAddress(port: RP_PAIRING_PORT)
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let tunnelErr = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                tunnel_create_rppairing(
                    sockaddrPointer,
                    addrLen,
                    "Music-Provider",
                    rpPairingHandle,
                    nil,
                    nil,
                    &rpAdapter,
                    &rpHandshake
                )
            }
        }

        guard tunnelErr == IdeviceSuccess, rpAdapter != nil, rpHandshake != nil else {
            self.logOnce("[DeviceManager] ERROR: RPPairing tunnel failed. Err: \(String(describing: tunnelErr))", key: "connection_status")
            resetConnectionHandles()
            return false
        }

        self.logOnce("[DeviceManager] RPPairing tunnel established via \(DEVICE_HOST):\(RP_PAIRING_PORT)", key: "connection_status")
        return true
    }

    
    func startHeartbeat(forceReconnect: Bool = false, completion: ((Bool) -> Void)? = nil) {
        refreshExpectedPairingFileState()
        guard hasValidExpectedPairingFile else {
            let message = "Invalid \(expectedPairingFileTitle)"
            Logger.shared.log("[DeviceManager] \(message). Import the correct file before connecting.")
            DispatchQueue.main.async {
                self.connectionStatus = message
                self.heartbeatReady = false
                completion?(false)
            }
            return
        }

        if !forceReconnect && heartbeatReady && hasActiveTransport && canStillReachDevice() {
            DispatchQueue.main.async {
                completion?(true)
            }
            return
        }

        lastHeartbeatAttemptStartedAt = Date()
        if Thread.isMainThread {
            self.connectionStatus = "Connecting..."
            self.heartbeatReady = false
        } else {
            DispatchQueue.main.sync {
                self.connectionStatus = "Connecting..."
                self.heartbeatReady = false
            }
        }

        resetConnectionHandles()
        
        
        heartbeatThread = Thread {
            let sessionID = self.heartbeatSessionID
            self.establishHeartbeat { success in
                DispatchQueue.main.async {
                    guard sessionID == self.heartbeatSessionID else { return }
                    if success {
                        self.connectionStatus = "Connection Lost"
                        self.heartbeatReady = false
                    } else {
                        self.connectionStatus = "Connection Failed"
                        self.heartbeatReady = false
                    }
                }
            }
        }
        heartbeatThread?.name = "HeartbeatThread"
        heartbeatThread?.start()
        
        if let completion = completion {
            DispatchQueue.global().async {
                
                for _ in 0..<20 {
                    if self.heartbeatReady && self.hasActiveTransport {
                        DispatchQueue.main.async { completion(true) }
                        return
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    func establishHeartbeat(_ completion: @escaping (Bool) -> Void) {
        resetConnectionHandles()
        let sessionID = heartbeatSessionID
        self.logOnce("[DeviceManager] Establishing \(connectionModeDescription) connection...", key: "connection_status")

        if requiresRPPairingTunnel {
            guard establishRPPairingTunnel() else {
                completion(false)
                return
            }
        } else {
            var addr = makeSocketAddress(port: UInt16(LOCKDOWN_PORT))

            var pairingPtr: IdevicePairingFile?
            let pairingErr = idevice_pairing_file_read(regularPairingFile.path, &pairingPtr)
            guard pairingErr == IdeviceSuccess, pairingPtr != nil else {
                self.logOnce("[DeviceManager] ERROR: Failed to read pairing file. Err: \(String(describing: pairingErr))", key: "connection_status")
                completion(false)
                return
            }

            let providerErr = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    idevice_tcp_provider_new(sockaddrPointer, pairingPtr, "Music-Provider", &provider)
                }
            }

            if provider == nil {
                self.logOnce("[DeviceManager] ERROR: Provider is nil. Err: \(String(describing: providerErr))", key: "connection_status")
                completion(false)
                return
            }
        }

        var hbClient: HeartbeatClientHandle?
        let err = connectHeartbeatClient(&hbClient)
        
        if err == IdeviceSuccess && hbClient != nil {
            self.logOnce("[DeviceManager] Heartbeat connected successfully!", key: "connection_status")
            
            DispatchQueue.main.async {
                self.connectionStatus = "Connected"
                self.heartbeatReady = true
                if !self.hasCompletedInitialAutoConnect {
                    self.hasCompletedInitialAutoConnect = true
                    self.stopAutoReconnectWatcher()
                }
            }
            
            if requiresRPPairingTunnel {
                while !Thread.current.isCancelled && sessionID == heartbeatSessionID {
                    Thread.sleep(forTimeInterval: 5)
                }

                heartbeat_client_free(hbClient)
                if sessionID == heartbeatSessionID {
                    resetConnectionHandles()
                    completion(true)
                }
                return
            }
            
            
            var consecutivePoloFailures = 0
            while !Thread.current.isCancelled && sessionID == heartbeatSessionID {
                var newInterval: UInt64 = 0
                let marcoErr = heartbeat_get_marco(hbClient, 10, &newInterval)
                if marcoErr != IdeviceSuccess {
                    Logger.shared.log("[DeviceManager] Heartbeat marco unavailable; keeping session alive and probing with polo.")
                }

                let poloErr = heartbeat_send_polo(hbClient)
                if poloErr != IdeviceSuccess {
                    consecutivePoloFailures += 1
                    Logger.shared.log("[DeviceManager] Heartbeat polo failed (\(consecutivePoloFailures)).")
                    if consecutivePoloFailures >= 3 {
                        Logger.shared.log("[DeviceManager] Heartbeat polo failed repeatedly. Marking connection lost.")
                        break
                    }
                } else {
                    consecutivePoloFailures = 0
                }
                
                DispatchQueue.main.async {
                    if !self.heartbeatReady {
                         self.heartbeatReady = true
                         self.connectionStatus = "Connected"
                    }
                }
                
                
                Thread.sleep(forTimeInterval: 5)
            }
            
            
            heartbeat_client_free(hbClient)
            if sessionID == heartbeatSessionID {
                resetConnectionHandles()
                completion(true)
            }
        } else {
            self.logOnce("[DeviceManager] ERROR: Heartbeat connection failed", key: "connection_status")
            resetConnectionHandles()
            completion(false)
        }
    }

    

    
    func sendSyncFinishedNotification() {
        var lockdownd: LockdowndClientHandle?
        let err = connectLockdownClient(&lockdownd)
        
        if err == IdeviceSuccess {
            var port: UInt16 = 0
            var ssl: Bool = false
            _ = lockdownd_start_service(lockdownd, "com.apple.mobile.notification_proxy", &port, &ssl)
            lockdownd_client_free(lockdownd)
        }
    }

    private func postRingtoneRefreshNotifications() {
        var npClient: NotificationProxyClientHandle?
        let npErr = connectNotificationProxyClient(&npClient)
        guard npErr == IdeviceSuccess, let npClient else {
            Logger.shared.log("[RingtoneNotify] Failed to connect notification_proxy")
            return
        }
        defer { notification_proxy_client_free(npClient) }

        let notifications = [
            "com.apple.itunes-mobdev.syncWillStart",
            "com.apple.itunes-mobdev.syncLockRequest",
            "com.apple.itunes-mobdev.syncDidStart",
            "com.apple.itunes-mobdev.syncDidFinish"
        ]

        for name in notifications {
            let result = name.withCString { cName in
                notification_proxy_post(npClient, cName)
            }
            if result == IdeviceSuccess {
                Logger.shared.log("[RingtoneNotify] Posted \(name)")
            } else {
                Logger.shared.log("[RingtoneNotify] Failed posting \(name)")
            }
        }
    }

    var killMusicBeforeInjectEnabled: Bool {
        return UserDefaults.standard.object(forKey: "killMusicBeforeInject") as? Bool ?? true
    }

    private func makeTemporaryProvider(label: String = "Music-Provider-Temp") -> IdeviceProviderHandle? {
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(UInt16(LOCKDOWN_PORT))
        inet_pton(AF_INET, "10.7.0.1", &addr.sin_addr)

        var pairingPtr: IdevicePairingFile?
        _ = idevice_pairing_file_read(regularPairingFile.path, &pairingPtr)
        guard pairingPtr != nil else { return nil }

        var temporaryProvider: IdeviceProviderHandle?
        let providerErr = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                idevice_tcp_provider_new(sockaddrPointer, pairingPtr, label, &temporaryProvider)
            }
        }
        guard providerErr == IdeviceSuccess, temporaryProvider != nil else {
            return nil
        }
        return temporaryProvider
    }

    private func withTemporaryProvider<T>(
        label: String = "Music-Provider-Temp",
        _ body: (IdeviceProviderHandle?) -> T
    ) -> T {
        guard let tempProvider = makeTemporaryProvider(label: label) else {
            return body(nil)
        }
        defer { idevice_provider_free(tempProvider) }
        return body(tempProvider)
    }

    @discardableResult
    private func terminateMusicApp(adapter: AdapterHandle, handshake: RsdHandshakeHandle) -> Bool {
        var appService: AppServiceHandle?
        let appErr = app_service_connect_rsd(adapter, handshake, &appService)
        guard appErr == IdeviceSuccess, let appServiceHandle = appService else {
            Logger.shared.log("[MusicKill] Failed to connect AppService")
            return false
        }
        defer { app_service_free(appServiceHandle) }

        var processes: UnsafeMutablePointer<ProcessTokenC>?
        var processCount: UInt = 0
        let listErr = app_service_list_processes(appServiceHandle, &processes, &processCount)
        guard listErr == IdeviceSuccess, let processList = processes, processCount > 0 else {
            Logger.shared.log("[MusicKill] No process list available")
            return false
        }
        defer { app_service_free_process_list(processList, processCount) }

        var terminatedAny = false
        for i in 0..<Int(processCount) {
            let token = processList[i]
            guard token.pid != 0 else { continue }
            let exe = token.executable_url.map { String(cString: $0) } ?? ""

            if exe.localizedCaseInsensitiveContains("MusicManager") {
                continue
            }

            let isAppleMusicProcess =
                exe.localizedCaseInsensitiveContains("MobileMusicPlayer")
                || exe.localizedCaseInsensitiveContains("/Music.app/Music")
                || exe.localizedCaseInsensitiveContains("/Applications/Music.app/")

            guard isAppleMusicProcess else { continue }

            Logger.shared.log("[MusicKill] Targeting Apple Music pid=\(token.pid) exe=\(exe)")

            var signalResp: UnsafeMutablePointer<SignalResponseC>?
            let termErr = app_service_send_signal(appServiceHandle, token.pid, 15, &signalResp)
            if signalResp != nil {
                app_service_free_signal_response(signalResp)
            }
            if termErr == IdeviceSuccess {
                terminatedAny = true
                Logger.shared.log("[MusicKill] Sent SIGTERM to pid=\(token.pid)")
            }

            Thread.sleep(forTimeInterval: 0.25)

            var killResp: UnsafeMutablePointer<SignalResponseC>?
            let killErr = app_service_send_signal(appServiceHandle, token.pid, 9, &killResp)
            if killResp != nil {
                app_service_free_signal_response(killResp)
            }
            if killErr == IdeviceSuccess {
                terminatedAny = true
                Logger.shared.log("[MusicKill] Sent SIGKILL to pid=\(token.pid)")
            }
        }

        return terminatedAny
    }

    @discardableResult
    private func terminateMusicAppIfRunning() -> Bool {
        if requiresRPPairingTunnel {
            guard let rpAdapter, let rpHandshake else {
                Logger.shared.log("[MusicKill] RPPairing tunnel unavailable")
                return false
            }
            return terminateMusicApp(adapter: rpAdapter, handshake: rpHandshake)
        }

        return withTemporaryProvider(label: "Music-Kill") { refreshProvider in
            guard let refreshProvider else { return false }

            var proxy: CoreDeviceProxyHandle?
            let proxyErr = core_device_proxy_connect(refreshProvider, &proxy)
            guard proxyErr == IdeviceSuccess, let proxyHandle = proxy else {
                Logger.shared.log("[MusicKill] CoreDevice proxy unavailable")
                return false
            }

            var rsdPort: UInt16 = 0
            let rsdErr = core_device_proxy_get_server_rsd_port(proxyHandle, &rsdPort)
            guard rsdErr == IdeviceSuccess, rsdPort > 0 else {
                Logger.shared.log("[MusicKill] Failed to resolve RSD port")
                return false
            }

            var adapter: AdapterHandle?
            let adapterErr = core_device_proxy_create_tcp_adapter(proxyHandle, &adapter)
            guard adapterErr == IdeviceSuccess, let adapterHandle = adapter else {
                Logger.shared.log("[MusicKill] Failed to create adapter")
                return false
            }
            defer { adapter_free(adapterHandle) }

            var stream: ReadWriteOpaqueHandle?
            let streamErr = adapter_connect(adapterHandle, rsdPort, &stream)
            guard streamErr == IdeviceSuccess, let streamHandle = stream else {
                Logger.shared.log("[MusicKill] Failed to connect adapter stream")
                return false
            }

            var handshake: RsdHandshakeHandle?
            let hsErr = rsd_handshake_new(streamHandle, &handshake)
            guard hsErr == IdeviceSuccess, let handshakeHandle = handshake else {
                Logger.shared.log("[MusicKill] Failed to create RSD handshake")
                return false
            }
            defer { rsd_handshake_free(handshakeHandle) }

            return terminateMusicApp(adapter: adapterHandle, handshake: handshakeHandle)
        }
    }
    
    
    
    
    func getDeviceProductVersion() -> String? {
        var lockdownd: LockdowndClientHandle?
        let err = connectLockdownClient(&lockdownd)
        
        guard err == IdeviceSuccess, let client = lockdownd else {
            return nil
        }
        defer { lockdownd_client_free(client) }
        
        var plist: plist_t?
        let valErr = lockdownd_get_value(client, "ProductVersion", nil, &plist)
        
        guard valErr == IdeviceSuccess, let versionPlist = plist else {
            return nil
        }
        defer { plist_free(versionPlist) }
        
        var cString: UnsafeMutablePointer<CChar>?
        plist_get_string_val(versionPlist, &cString)
        
        if let cString = cString {
            let version = String(cString: cString)
            plist_mem_free(cString)
            return version
        }
        
        return nil
    }
    
    func getDatabaseVersion() -> DatabaseVersion {
        guard let versionString = getDeviceProductVersion() else {
            Logger.shared.log("[DeviceManager] Could not detect version, defaulting to iOS 16/26 schema")
            return .ios(16)
        }
        
        Logger.shared.log("[DeviceManager] Detected device version: \(versionString)")
        let components = versionString.split(separator: ".").compactMap { Int($0) }
        guard let major = components.first else { return .ios(16) }
        let minor = components.count > 1 ? components[1] : 0
        let patch = components.count > 2 ? components[2] : 0
        
        return .ios(major, minor: minor, patch: patch)
    }

    func triggerATCSync(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var lockdownd: LockdowndClientHandle?
            let err = self.connectLockdownClient(&lockdownd)
            
            guard err == IdeviceSuccess else {
                Logger.shared.log("[DeviceManager] Failed to connect lockdownd for ATC")
                completion(false)
                return
            }
            
            var port: UInt16 = 0
            var ssl: Bool = false
            let _ = lockdownd_start_service(lockdownd, "com.apple.atc", &port, &ssl)
            
            lockdownd_client_free(lockdownd)
            
            if port > 0 {
                
                completion(true)
            } else {
                Logger.shared.log("[DeviceManager] Failed to get ATC port")
                completion(false)
            }
        }
    }
    
    
    

    func addSongToDevice(localURL: URL, filename: String, completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] addSongToDevice called for: \(filename)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            var file: AfcFileHandle?
            
            let needsSecurityScope = localURL.startAccessingSecurityScopedResource()
            Logger.shared.log("[DeviceManager] Security scoped access needed: \(needsSecurityScope)")
            defer {
                if needsSecurityScope {
                    localURL.stopAccessingSecurityScopedResource()
                }
            }
            
            Logger.shared.log("[DeviceManager] File exists: \(FileManager.default.fileExists(atPath: localURL.path))")

            Logger.shared.log("[DeviceManager] Connecting AFC client...")
            self.connectAfcClient(&afc)
            Logger.shared.log("[DeviceManager] AFC client connected: \(afc != nil)")
            
            guard afc != nil else {
                Logger.shared.log("[DeviceManager] ERROR: AFC client is nil")
                completion(false)
                return
            }
            
            
            let musicDir = "/iTunes_Control/Music/F00"
            Logger.shared.log("[DeviceManager] Creating directory: \(musicDir)")
            afc_make_directory(afc, musicDir)
            
            let remotePath = "\(musicDir)/\(filename)"
            Logger.shared.log("[DeviceManager] Opening remote file: \(remotePath)")
            afc_file_open(afc, remotePath, AfcWrOnly, &file)
            
            guard file != nil else {
                Logger.shared.log("[DeviceManager] ERROR: Could not open remote file")
                afc_client_free(afc)
                completion(false)
                return
            }
            
            if let data = try? Data(contentsOf: localURL) {
                
                data.withUnsafeBytes { buffer in
                    if let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        afc_file_write(file, base, data.count)
                    }
                }
                
            } else {
                Logger.shared.log("[DeviceManager] ERROR: Could not read file data from \(localURL.path)")
                afc_file_close(file)
                afc_client_free(afc)
                completion(false)
                return
            }
            
            afc_file_close(file)
            afc_client_free(afc)
            
            self.sendSyncFinishedNotification()
            Logger.shared.log("[DeviceManager] addSongToDevice complete")
            completion(true)
        }
    }
    
    
    
    func removeFileFromDevice(remotePath: String, completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] removeFileFromDevice called for: \(remotePath)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            
            self.connectAfcClient(&afc)
            
            guard afc != nil else {
                Logger.shared.log("[DeviceManager] ERROR: AFC client is nil for deletion")
                completion(false)
                return
            }
            
            
            let err = afc_remove_path(afc, remotePath)
            
            
            afc_client_free(afc)
            completion(err == nil)
        }
    }
    
    
    
    func deleteMediaLibrary(completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] DELETING MEDIA LIBRARY (NUKE)...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            if self.killMusicBeforeInjectEnabled {
                let killed = self.terminateMusicAppIfRunning()
                Logger.shared.log("[DeviceManager] Pre-delete Music kill \(killed ? "completed" : "skipped/failed")")
            }

            var afc: AfcClientHandle?
            let connectErr = self.connectAfcClient(&afc)
            
            guard afc != nil else {
                Logger.shared.log("[DeviceManager] ERROR: AFC client is nil for library reset (Error: \(String(describing: connectErr)))")
                completion(false)
                return
            }
            
            
            
            let iTunesPath = "/iTunes_Control/iTunes"
            Logger.shared.log("[DeviceManager] Removing \(iTunesPath) and all contents...")
            
            

            _ = afc_remove_path_and_contents(afc, iTunesPath)
            
            
            Logger.shared.log("[DeviceManager] Recreating \(iTunesPath)...")
            _ = afc_make_directory(afc, iTunesPath)
            
            
             _ = afc_make_directory(afc, "/iTunes_Control/iTunes/Artwork")
             _ = afc_make_directory(afc, "/iTunes_Control/iTunes/Artwork/Originals")
            
            afc_client_free(afc)

            
            self.sendSyncFinishedNotification()
            Logger.shared.log("[DeviceManager] Library nuke complete.")
            completion(true)
        }
    }
    
    func createDatabaseSnapshot(progress: SnapshotProgressHandler? = nil, completion: @escaping (Bool, String) -> Void) {
        Logger.shared.log("[Backup] Creating database snapshot...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            progress?("Preparing backup...", nil)
            let fullBackupEnabled = UserDefaults.standard.bool(forKey: "fullBackupSnapshots")
            if self.killMusicBeforeInjectEnabled {
                let killed = self.terminateMusicAppIfRunning()
                Logger.shared.log("[Backup] Pre-snapshot Music kill \(killed ? "completed" : "skipped/failed")")
            }
            
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let stamp = formatter.string(from: Date())
            
            let root = self.snapshotsDirectoryURL
            let folder = root.appendingPathComponent("snapshot_\(stamp)", isDirectory: true)
            
            if let existing = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for entry in existing where entry.hasDirectoryPath && entry.lastPathComponent.hasPrefix("snapshot_") {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
            
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                Logger.shared.log("[Backup] Failed creating snapshot folder: \(error)")
                completion(false, "Failed creating snapshot folder")
                return
            }
            
            let files: [(remote: String, local: String, required: Bool)] = [
                ("/iTunes_Control/iTunes/MediaLibrary.sqlitedb", "MediaLibrary.sqlitedb", true),
                ("/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal", "MediaLibrary.sqlitedb-wal", false),
                ("/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm", "MediaLibrary.sqlitedb-shm", false),
                ("/iTunes_Control/Ringtones/Ringtones.plist", "Ringtones.plist", false)
            ]
            
            var saved: [String] = []
            for (index, item) in files.enumerated() {
                progress?("Backing up database files \(index + 1)/\(files.count)...", Double(index + 1) / Double(files.count) * 0.25)
                let localURL = folder.appendingPathComponent(item.local)
                let sem = DispatchSemaphore(value: 0)
                var success = false
                self.downloadFileFromDevice(remotePath: item.remote, localURL: localURL) { ok in
                    success = ok
                    sem.signal()
                }
                sem.wait()
                
                if success {
                    saved.append(item.local)
                    Logger.shared.log("[Backup] Saved \(item.local)")
                } else if item.required {
                    Logger.shared.log("[Backup] Required file missing: \(item.remote)")
                    try? FileManager.default.removeItem(at: folder)
                    completion(false, "Failed: MediaLibrary.sqlitedb unavailable")
                    return
                }
            }
            
            if !saved.contains("MediaLibrary.sqlitedb") {
                Logger.shared.log("[Backup] Snapshot invalid (no DB file)")
                try? FileManager.default.removeItem(at: folder)
                completion(false, "Failed: DB file missing")
                return
            }
            
            let dbLocal = folder.appendingPathComponent("MediaLibrary.sqlitedb")
            progress?("Indexing music files...", fullBackupEnabled ? 0.28 : 0.45)
            let musicFiles = Array(self.musicFilenamesFromDatabase(dbLocal)).sorted()
            self.writeSnapshotManifest(musicFiles, to: folder.appendingPathComponent(self.snapshotMusicManifestName))
            Logger.shared.log("[Backup] Indexed \(musicFiles.count) music filenames for rollback safety")
            
            progress?("Indexing artwork...", fullBackupEnabled ? 0.32 : 0.55)
            let artworkPaths = self.artworkPathsFromDatabase(dbLocal)
            self.writeSnapshotManifest(artworkPaths, to: folder.appendingPathComponent(self.snapshotArtworkManifestName))
            Logger.shared.log("[Backup] Indexed \(artworkPaths.count) artwork paths")
            
            if fullBackupEnabled {
                Logger.shared.log("[Backup] Separate artwork backup skipped for full backup")
            } else {
                let artworkRoot = folder.appendingPathComponent(self.snapshotArtworkDirectory, isDirectory: true)
                var artworkSaved = 0
                if !artworkPaths.isEmpty {
                    try? FileManager.default.createDirectory(at: artworkRoot, withIntermediateDirectories: true)
                    for (index, relativePath) in artworkPaths.enumerated() {
                        progress?("Backing up artwork \(index + 1)/\(artworkPaths.count)...", 0.58 + (Double(index + 1) / Double(artworkPaths.count) * 0.34))
                        let localURL = artworkRoot.appendingPathComponent(relativePath)
                        let localDir = localURL.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
                        
                        let remotePath = "/iTunes_Control/iTunes/Artwork/Originals/\(relativePath)"
                        let sem = DispatchSemaphore(value: 0)
                        var downloaded = false
                        self.downloadFileFromDevice(remotePath: remotePath, localURL: localURL) { ok in
                            downloaded = ok
                            sem.signal()
                        }
                        sem.wait()
                        
                        if downloaded {
                            artworkSaved += 1
                        } else {
                            try? FileManager.default.removeItem(at: localURL)
                        }
                    }
                }
                Logger.shared.log("[Backup] Artwork saved: \(artworkSaved)/\(artworkPaths.count)")
            }

            if fullBackupEnabled {
                progress?("Scanning full iTunes folder...", 0.38)
                Logger.shared.log("[Backup] Full backup enabled, copying iTunes/Music folders...")
                let fullResult = self.createFullITunesBackupCopy(in: folder) { message, value in
                    progress?(message, value)
                }
                guard fullResult.success else {
                    Logger.shared.log("[Backup] Full backup failed: \(fullResult.message)")
                    completion(false, fullResult.message)
                    return
                }
                Logger.shared.log("[Backup] Full backup copy created: \(fullResult.message)")
            }
            
            progress?("Backup complete.", 1)
            Logger.shared.log("[Backup] Snapshot complete: \(folder.lastPathComponent) (\(saved.count) files)")
            completion(true, fullBackupEnabled ? "Full snapshot created: \(folder.lastPathComponent)" : "Snapshot created: \(folder.lastPathComponent)")
        }
    }
    
    func restoreLatestDatabaseSnapshot(progress: SnapshotProgressHandler? = nil, completion: @escaping (Bool, String) -> Void) {
        Logger.shared.log("[Backup] Restoring latest database snapshot...")
        
        DispatchQueue.global(qos: .userInitiated).async {
            progress?("Finding latest backup...", nil)
            let root = self.snapshotsDirectoryURL
            let fm = FileManager.default
            
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                completion(false, "No snapshots found")
                return
            }
            
            let snapshotDirs = entries.filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("snapshot_") }
            guard !snapshotDirs.isEmpty else {
                completion(false, "No snapshots found")
                return
            }
            
            let sorted = snapshotDirs.sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
            
            guard let latest = sorted.first else {
                completion(false, "No snapshots found")
                return
            }
            self.restoreSnapshotDirectory(latest, progress: progress, completion: completion)
        }
    }
    
    func restoreDatabaseSnapshot(named folderName: String, progress: SnapshotProgressHandler? = nil, completion: @escaping (Bool, String) -> Void) {
        Logger.shared.log("[Backup] Restoring snapshot: \(folderName)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            let snapshotDir = self.snapshotsDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: snapshotDir.path) else {
                completion(false, "Snapshot not found")
                return
            }
            self.restoreSnapshotDirectory(snapshotDir, progress: progress, completion: completion)
        }
    }
    
    func deleteDatabaseSnapshot(named folderName: String, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let path = self.snapshotsDirectoryURL.appendingPathComponent(folderName, isDirectory: true)
            do {
                try FileManager.default.removeItem(at: path)
                Logger.shared.log("[Backup] Deleted snapshot: \(folderName)")
                completion(true, "Deleted: \(folderName)")
            } catch {
                Logger.shared.log("[Backup] Failed deleting snapshot \(folderName): \(error)")
                completion(false, "Delete failed")
            }
        }
    }
    
    private func restoreSnapshotDirectory(_ snapshotDir: URL, progress: SnapshotProgressHandler? = nil, completion: @escaping (Bool, String) -> Void) {
        progress?("Preparing restore...", nil)
        let fm = FileManager.default
        let dbLocal = snapshotDir.appendingPathComponent("MediaLibrary.sqlitedb")
        let fullBackupRoot = snapshotDir.appendingPathComponent(snapshotFullBackupDirectory, isDirectory: true)

        if fm.fileExists(atPath: fullBackupRoot.path) {
            restoreFullITunesBackupCopy(fullBackupRoot, progress: progress, completion: completion)
            return
        }

        guard fm.fileExists(atPath: dbLocal.path) else {
            completion(false, "Snapshot missing MediaLibrary.sqlitedb")
            return
        }
        
        if self.killMusicBeforeInjectEnabled {
            let killed = self.terminateMusicAppIfRunning()
            Logger.shared.log("[Backup] Pre-restore Music kill \(killed ? "completed" : "skipped/failed")")
        }
        
        var afc: AfcClientHandle?
        self.connectAfcClient(&afc)
        guard let afc else {
            completion(false, "AFC connection failed")
            return
        }
        defer { afc_client_free(afc) }
        
        let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
        let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
        let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
        let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
        let ringtonePath = "/iTunes_Control/Ringtones/Ringtones.plist"
        
        progress?("Uploading database...", 0.25)
        _ = afc_make_directory(afc, "/iTunes_Control/iTunes")
        _ = afc_make_directory(afc, "/iTunes_Control/Ringtones")
        
        let semUploadDB = DispatchSemaphore(value: 0)
        var dbUploadOK = false
        self.uploadFileToDevice(localURL: dbLocal, remotePath: tempDBPath) { ok in
            dbUploadOK = ok
            semUploadDB.signal()
        }
        semUploadDB.wait()
        
        guard dbUploadOK else {
            completion(false, "Failed uploading snapshot DB")
            return
        }
        
        progress?("Swapping database...", 0.55)
        guard self.replaceRemoteMediaLibrary(
            tempDBPath: tempDBPath,
            finalDBPath: finalDBPath,
            shmPath: shmPath,
            walPath: walPath,
            afc: afc,
            logContext: "[Backup]"
        ) else {
            Logger.shared.log("[Backup] Rename failed while restoring DB")
            completion(false, "Failed swapping restored DB")
            return
        }
        
        let ringtoneLocal = snapshotDir.appendingPathComponent("Ringtones.plist")
        if fm.fileExists(atPath: ringtoneLocal.path) {
            progress?("Restoring ringtones...", 0.65)
            let semRingtone = DispatchSemaphore(value: 0)
            self.uploadFileToDevice(localURL: ringtoneLocal, remotePath: ringtonePath) { _ in
                semRingtone.signal()
            }
            semRingtone.wait()
        }
        
        let artworkRoot = snapshotDir.appendingPathComponent(snapshotArtworkDirectory, isDirectory: true)
        var restoredArtwork = 0
        if fm.fileExists(atPath: artworkRoot.path) {
            _ = afc_make_directory(afc, "/iTunes_Control/iTunes/Artwork")
            _ = afc_make_directory(afc, "/iTunes_Control/iTunes/Artwork/Originals")
            
            if let enumerator = fm.enumerator(at: artworkRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    
                    let relative = fileURL.path.replacingOccurrences(of: artworkRoot.path + "/", with: "")
                    guard !relative.isEmpty else { continue }
                    
                    progress?("Restoring artwork \(restoredArtwork + 1)...", nil)
                    let remote = "/iTunes_Control/iTunes/Artwork/Originals/\(relative)"
                    let semArt = DispatchSemaphore(value: 0)
                    self.uploadFileToDevice(localURL: fileURL, remotePath: remote) { ok in
                        if ok {
                            restoredArtwork += 1
                        }
                        semArt.signal()
                    }
                    semArt.wait()
                }
            }
        }
        Logger.shared.log("[Backup] Restored artwork files: \(restoredArtwork)")
        
        progress?("Restore complete.", 1)
        self.sendSyncFinishedNotification()
        Logger.shared.log("[Backup] Restore complete from \(snapshotDir.lastPathComponent)")
        completion(true, "Restored: \(snapshotDir.lastPathComponent)")
    }

    private func createFullITunesBackupCopy(in snapshotDir: URL, progress: SnapshotProgressHandler? = nil) -> (success: Bool, message: String) {
        let fm = FileManager.default
        let backupRoot = snapshotDir.appendingPathComponent(snapshotFullBackupDirectory, isDirectory: true)

        try? fm.removeItem(at: backupRoot)

        do {
            try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        } catch {
            return (false, "Failed creating full backup folder")
        }

        var afc: AfcClientHandle?
        self.connectAfcClient(&afc)
        guard let afc else {
            try? fm.removeItem(at: backupRoot)
            return (false, "AFC unavailable for full backup")
        }
        defer { afc_client_free(afc) }

        let roots = [
            "/iTunes_Control/iTunes",
            "/iTunes_Control/Music",
            "/iTunes_Control/Ringtones"
        ]

        var remoteFiles: [String] = []
        for remoteRoot in roots {
            remoteFiles.append(contentsOf: listRemoteFilesForBackup(afc: afc, remotePath: remoteRoot))
        }

        guard !remoteFiles.isEmpty else {
            try? fm.removeItem(at: backupRoot)
            return (false, "No files found for full backup")
        }

        var copied = 0
        for (index, remotePath) in remoteFiles.enumerated() {
            progress?("Copying full backup files \(index + 1)/\(remoteFiles.count)...", 0.48 + (Double(index + 1) / Double(remoteFiles.count) * 0.48))
            let relative = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let localURL = backupRoot.appendingPathComponent(relative)
            copied += copyRemoteFileToLocal(afc: afc, remotePath: remotePath, localURL: localURL)
        }

        guard copied > 0 else {
            try? fm.removeItem(at: backupRoot)
            return (false, "No files found for full backup")
        }

        progress?("Full backup copy saved.", 0.98)
        let size = directorySize(backupRoot)
        return (true, "Full backup saved (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
    }

    private func restoreFullITunesBackupCopy(_ backupRoot: URL, progress: SnapshotProgressHandler? = nil, completion: @escaping (Bool, String) -> Void) {
        Logger.shared.log("[Backup] Restoring full backup copy...")
        progress?("Preparing full backup restore...", 0.12)

        if self.killMusicBeforeInjectEnabled {
            let killed = self.terminateMusicAppIfRunning()
            Logger.shared.log("[Backup] Pre-full-restore Music kill \(killed ? "completed" : "skipped/failed")")
        }

        var afc: AfcClientHandle?
        self.connectAfcClient(&afc)
        guard let afc else {
            completion(false, "AFC unavailable for full restore")
            return
        }
        defer { afc_client_free(afc) }

        progress?("Clearing device iTunes folders...", 0.28)
        for path in ["/iTunes_Control/iTunes", "/iTunes_Control/Music", "/iTunes_Control/Ringtones"] {
            _ = afc_remove_path_and_contents(afc, path)
        }
        _ = afc_make_directory(afc, "/iTunes_Control")

        let localITunesControl = backupRoot.appendingPathComponent("iTunes_Control", isDirectory: true)
        let filesToRestore = localFilesForBackupRestore(under: localITunesControl)
        let restored = uploadLocalTreeToRemote(
            afc: afc,
            localURL: localITunesControl,
            remotePath: "/iTunes_Control",
            progress: { uploaded, _ in
                let total = max(filesToRestore.count, 1)
                progress?("Restoring full backup files \(min(uploaded, total))/\(total)...", 0.34 + (Double(min(uploaded, total)) / Double(total) * 0.58))
            }
        )

        guard restored > 0 else {
            completion(false, "No files restored from full backup")
            return
        }

        self.sendSyncFinishedNotification()
        progress?("Full restore complete.", 1)
        Logger.shared.log("[Backup] Full restore complete, restored \(restored) files")
        completion(true, "Full snapshot restored. Restart Music if it is still cached.")
    }

    private func listRemoteFilesForBackup(afc: AfcClientHandle, remotePath: String) -> [String] {
        var info = AfcFileInfo()
        let infoErr = afc_get_file_info(afc, remotePath, &info)
        guard infoErr == nil else {
            return []
        }
        defer { afc_file_info_free(&info) }

        let type = info.st_ifmt.map { String(cString: $0) } ?? ""
        guard type == "S_IFDIR" else {
            return [remotePath]
        }

        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count: Int = 0
        let listErr = afc_list_directory(afc, remotePath, &entries, &count)
        guard listErr == nil, let entries else {
            return []
        }
        defer { free(entries) }

        var files: [String] = []
        for index in 0..<count {
            guard let ptr = entries[index] else { continue }
            let name = String(cString: ptr)
            guard name != "." && name != ".." else { continue }
            files.append(contentsOf: listRemoteFilesForBackup(afc: afc, remotePath: "\(remotePath)/\(name)"))
        }
        return files
    }

    private func copyRemoteFileToLocal(afc: AfcClientHandle, remotePath: String, localURL: URL) -> Int {
        let fm = FileManager.default

        var file: AfcFileHandle?
        afc_file_open(afc, remotePath, AfcRdOnly, &file)
        guard let file else {
            return 0
        }
        defer { afc_file_close(file) }

        var dataPtr: UnsafeMutablePointer<UInt8>?
        var length: Int = 0
        let readErr = afc_file_read_entire(file, &dataPtr, &length)
        guard readErr == nil, let dataPtr, length > 0 else {
            return 0
        }
        defer { afc_file_read_data_free(dataPtr, length) }

        do {
            try fm.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes: dataPtr, count: length).write(to: localURL)
            return 1
        } catch {
            Logger.shared.log("[Backup] Failed saving \(remotePath): \(error)")
            return 0
        }
    }

    private func uploadLocalTreeToRemote(afc: AfcClientHandle, localURL: URL, remotePath: String, progress: ((Int, String) -> Void)? = nil) -> Int {
        var uploadedCount = 0
        return uploadLocalTreeToRemote(afc: afc, localURL: localURL, remotePath: remotePath, progress: progress, uploadedCount: &uploadedCount)
    }

    private func uploadLocalTreeToRemote(afc: AfcClientHandle, localURL: URL, remotePath: String, progress: ((Int, String) -> Void)?, uploadedCount: inout Int) -> Int {
        let fm = FileManager.default
        guard let values = try? localURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
            return 0
        }

        if values.isDirectory == true {
            _ = afc_make_directory(afc, remotePath)
            guard let entries = try? fm.contentsOfDirectory(at: localURL, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
                return 0
            }

            var uploaded = 0
            for entry in entries {
                uploaded += uploadLocalTreeToRemote(
                    afc: afc,
                    localURL: entry,
                    remotePath: "\(remotePath)/\(entry.lastPathComponent)",
                    progress: progress,
                    uploadedCount: &uploadedCount
                )
            }
            return uploaded
        }

        guard values.isRegularFile == true,
              let data = try? Data(contentsOf: localURL) else {
            return 0
        }

        _ = afc_make_directory(afc, (remotePath as NSString).deletingLastPathComponent)
        _ = afc_remove_path(afc, remotePath)

        var file: AfcFileHandle?
        afc_file_open(afc, remotePath, AfcWrOnly, &file)
        guard let file else {
            return 0
        }
        defer { afc_file_close(file) }

        data.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                afc_file_write(file, base, data.count)
            }
        }

        uploadedCount += 1
        progress?(uploadedCount, remotePath)
        return 1
    }

    private func localFilesForBackupRestore(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files
    }

    private func directorySize(_ root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += values.fileSize ?? 0
        }
        return total
    }

    private func countSongsInSnapshotDB(_ dbURL: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM item WHERE media_type = 8", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
            if count > 0 { return count }
        } else if stmt != nil {
            sqlite3_finalize(stmt)
        }
        
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM item", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        if stmt != nil { sqlite3_finalize(stmt) }
        return count
    }
    
    private func musicFilenamesFromDatabase(_ dbURL: URL) -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        
        var stmt: OpaquePointer?
        var names = Set<String>()
        
        let sql = """
        SELECT item_extra.location
        FROM item
        INNER JOIN item_extra ON item.item_pid = item_extra.item_pid
        WHERE item.base_location_id = 3840
          AND item.media_type = 8
          AND item_extra.location != ''
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    let location = String(cString: ptr)
                    let filename = (location as NSString).lastPathComponent
                    if !filename.isEmpty {
                        names.insert(filename)
                    }
                }
            }
        }
        if stmt != nil { sqlite3_finalize(stmt) }
        
        if !names.isEmpty {
            return names
        }
        
        if sqlite3_prepare_v2(db, "SELECT location FROM item_extra WHERE location != ''", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    let location = String(cString: ptr)
                    let filename = (location as NSString).lastPathComponent
                    if !filename.isEmpty {
                        names.insert(filename)
                    }
                }
            }
        }
        if stmt != nil { sqlite3_finalize(stmt) }
        
        return names
    }
    
    private func artworkPathsFromDatabase(_ dbURL: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        
        var stmt: OpaquePointer?
        var paths = Set<String>()
        if sqlite3_prepare_v2(db, "SELECT relative_path FROM artwork WHERE relative_path != ''", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 0) {
                    let rel = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rel.isEmpty {
                        paths.insert(rel)
                    }
                }
            }
        }
        if stmt != nil { sqlite3_finalize(stmt) }
        
        return paths.sorted()
    }
    
    private func writeSnapshotManifest(_ lines: [String], to manifestURL: URL) {
        let content = lines.joined(separator: "\n")
        try? content.write(to: manifestURL, atomically: true, encoding: .utf8)
    }
    
    private func loadSnapshotMusicFilenames(snapshotDir: URL) -> Set<String> {
        let manifestURL = snapshotDir.appendingPathComponent(snapshotMusicManifestName)
        if
            let content = try? String(contentsOf: manifestURL, encoding: .utf8),
            !content.isEmpty
        {
            let set = Set(
                content
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            if !set.isEmpty {
                return set
            }
        }
        
        let dbURL = snapshotDir.appendingPathComponent("MediaLibrary.sqlitedb")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }
        return musicFilenamesFromDatabase(dbURL)
    }
    
    private func protectedFilenamesFromAllSnapshots() -> Set<String> {
        let fm = FileManager.default
        let root = snapshotsDirectoryURL
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var protectedSet = Set<String>()
        for dir in entries where dir.hasDirectoryPath && dir.lastPathComponent.hasPrefix("snapshot_") {
            let names = loadSnapshotMusicFilenames(snapshotDir: dir)
            if !names.isEmpty {
                protectedSet.formUnion(names)
            }
        }
        return protectedSet
    }
    
    private struct CarrySongDBMetadata {
        let itemPid: Int64
        let title: String
        let artist: String
        let album: String
        let genre: String
        let year: Int
        let durationMs: Int
        let fileSize: Int
        let trackNumber: Int?
        let lyrics: String?
        let explicitRating: Int
        let artworkRelativePath: String?
    }
    
    private func firstStringQuery(db: OpaquePointer?, sql: String, itemPid: Int64) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if stmt != nil { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, itemPid)
        if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
            let value = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }
    
    private func artworkPathForItemPid(db: OpaquePointer?, itemPid: Int64) -> String? {
        let candidates = [
            """
            SELECT aw.relative_path
            FROM best_artwork_token bat
            JOIN artwork aw ON aw.artwork_token = bat.available_artwork_token
            WHERE bat.entity_pid = ? AND aw.relative_path != ''
            LIMIT 1
            """,
            """
            SELECT aw.relative_path
            FROM best_artwork_token bat
            JOIN artwork aw ON aw.artwork_token = bat.fetchable_artwork_token
            WHERE bat.entity_pid = ? AND aw.relative_path != ''
            LIMIT 1
            """,
            """
            SELECT aw.relative_path
            FROM artwork_token atok
            JOIN artwork aw ON aw.artwork_token = atok.artwork_token
            WHERE atok.entity_pid = ? AND aw.relative_path != ''
            LIMIT 1
            """
        ]
        
        for sql in candidates {
            if let rel = firstStringQuery(db: db, sql: sql, itemPid: itemPid) {
                return rel
            }
        }
        return nil
    }
    
    private func carrySongMetadataMapFromDatabase(_ dbURL: URL) -> [String: CarrySongDBMetadata] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return [:] }
        defer { sqlite3_close(db) }
        
        let sql = """
        SELECT
            i.item_pid,
            ie.location,
            ie.title,
            IFNULL(ia.item_artist, ''),
            IFNULL(al.album, ''),
            IFNULL(ge.genre, ''),
            ie.year,
            CAST(ie.total_time_ms AS INTEGER),
            ie.file_size,
            i.track_number,
            ie.content_rating
        FROM item i
        JOIN item_extra ie ON ie.item_pid = i.item_pid
        LEFT JOIN item_artist ia ON ia.item_artist_pid = i.item_artist_pid
        LEFT JOIN album al ON al.album_pid = i.album_pid
        LEFT JOIN genre ge ON ge.genre_id = i.genre_id
        WHERE ie.location != ''
        """
        
        var stmt: OpaquePointer?
        var map: [String: CarrySongDBMetadata] = [:]
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if stmt != nil { sqlite3_finalize(stmt) }
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let itemPid = sqlite3_column_int64(stmt, 0)
            guard let locPtr = sqlite3_column_text(stmt, 1) else { continue }
            let location = String(cString: locPtr)
            let filename = (location as NSString).lastPathComponent
            if filename.isEmpty { continue }
            
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            let artist = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Unknown Artist"
            let album = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "Unknown Album"
            let genre = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "Music"
            let year = Int(sqlite3_column_int(stmt, 6))
            let durationMs = Int(sqlite3_column_int(stmt, 7))
            let fileSize = Int(sqlite3_column_int(stmt, 8))
            let trackNumber = Int(sqlite3_column_int(stmt, 9))
            let explicitRating = Int(sqlite3_column_int(stmt, 10))
            let lyrics = firstStringQuery(
                db: db,
                sql: "SELECT lyrics FROM lyrics WHERE item_pid = ? LIMIT 1",
                itemPid: itemPid
            )
            let artworkRelativePath = artworkPathForItemPid(db: db, itemPid: itemPid)
            
            map[filename] = CarrySongDBMetadata(
                itemPid: itemPid,
                title: title.isEmpty ? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent : title,
                artist: artist.isEmpty ? "Unknown Artist" : artist,
                album: album.isEmpty ? "Unknown Album" : album,
                genre: genre.isEmpty ? "Music" : genre,
                year: year > 0 ? year : Calendar.current.component(.year, from: Date()),
                durationMs: max(0, durationMs),
                fileSize: max(0, fileSize),
                trackNumber: trackNumber > 0 ? trackNumber : nil,
                lyrics: lyrics,
                explicitRating: explicitRating,
                artworkRelativePath: (artworkRelativePath?.isEmpty == false) ? artworkRelativePath : nil
            )
        }
        
        Logger.shared.log("[Backup] Carry-over metadata map loaded for \(map.count) songs")
        return map
    }
    
    private func buildCarryOverSongsForSnapshotRestore(excluding snapshotFilenames: Set<String>) -> (songs: [SongMetadata], filenames: [String], artworkRelativePaths: [String: String], stagingDir: URL?) {
        let fm = FileManager.default
        
        let semDb = DispatchSemaphore(value: 0)
        var currentDbData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
            currentDbData = data
            semDb.signal()
        }
        semDb.wait()
        
        guard let currentDbData, currentDbData.count > 10000 else {
            return ([], [], [:], nil)
        }
        
        let semWal = DispatchSemaphore(value: 0)
        var walData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
            walData = data
            semWal.signal()
        }
        semWal.wait()
        
        let semShm = DispatchSemaphore(value: 0)
        var shmData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
            shmData = data
            semShm.signal()
        }
        semShm.wait()
        
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("restore_carry_\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            Logger.shared.log("[Backup] Failed to create carry-over staging dir: \(error)")
            return ([], [], [:], nil)
        }
        
        let dbPath = stagingDir.appendingPathComponent("CurrentMediaLibrary.sqlitedb")
        do {
            try currentDbData.write(to: dbPath)
            if let walData {
                try walData.write(to: stagingDir.appendingPathComponent("CurrentMediaLibrary.sqlitedb-wal"))
            }
            if let shmData {
                try shmData.write(to: stagingDir.appendingPathComponent("CurrentMediaLibrary.sqlitedb-shm"))
            }
        } catch {
            Logger.shared.log("[Backup] Failed to stage current DB for merge capture: \(error)")
            try? fm.removeItem(at: stagingDir)
            return ([], [], [:], nil)
        }
        
        let currentFilenames = musicFilenamesFromDatabase(dbPath)
        let carryFilenames = currentFilenames.subtracting(snapshotFilenames).sorted()
        guard !carryFilenames.isEmpty else {
            return ([], [], [:], stagingDir)
        }
        let metadataMap = carrySongMetadataMapFromDatabase(dbPath)
        
        let carrySongsDir = stagingDir.appendingPathComponent("carry_songs", isDirectory: true)
        try? fm.createDirectory(at: carrySongsDir, withIntermediateDirectories: true)
        let carryArtworkRoot = stagingDir.appendingPathComponent("carry_artwork", isDirectory: true)
        try? fm.createDirectory(at: carryArtworkRoot, withIntermediateDirectories: true)
        
        var songs: [SongMetadata] = []
        var carryArtworkRelativePaths: [String: String] = [:]
        songs.reserveCapacity(carryFilenames.count)
        
        for filename in carryFilenames {
            let localURL = carrySongsDir.appendingPathComponent(filename)
            let remotePath = "/iTunes_Control/Music/F00/\(filename)"
            
            let semDownload = DispatchSemaphore(value: 0)
            var downloaded = false
            self.downloadFileFromDevice(remotePath: remotePath, localURL: localURL) { ok in
                downloaded = ok
                semDownload.signal()
            }
            semDownload.wait()
            
            guard downloaded else {
                Logger.shared.log("[Backup] Carry-over skip: device file missing \(filename)")
                continue
            }
            
            var parsed: SongMetadata?
            let semMeta = DispatchSemaphore(value: 0)
            Task {
                parsed = try? await SongMetadata.fromURL(localURL)
                semMeta.signal()
            }
            semMeta.wait()
            
            if var song = parsed {
                if let dbMeta = metadataMap[filename] {
                    song.title = dbMeta.title
                    song.artist = dbMeta.artist
                    song.album = dbMeta.album
                    song.genre = dbMeta.genre
                    song.year = dbMeta.year
                    song.durationMs = dbMeta.durationMs > 0 ? dbMeta.durationMs : song.durationMs
                    song.fileSize = dbMeta.fileSize > 0 ? dbMeta.fileSize : song.fileSize
                    song.lyrics = dbMeta.lyrics ?? song.lyrics
                    if song.artworkData == nil, let rel = dbMeta.artworkRelativePath {
                        carryArtworkRelativePaths[filename] = rel
                        let semArt = DispatchSemaphore(value: 0)
                        var artData: Data?
                        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/Artwork/Originals/\(rel)") { data in
                            artData = data
                            semArt.signal()
                        }
                        semArt.wait()
                        if let artData {
                            song.artworkData = artData
                            let artLocalURL = carryArtworkRoot.appendingPathComponent(rel)
                            let artDir = artLocalURL.deletingLastPathComponent()
                            try? fm.createDirectory(at: artDir, withIntermediateDirectories: true)
                            try? artData.write(to: artLocalURL)
                        }
                    }
                } else {
                    Logger.shared.log("[Backup] Carry-over metadata fallback to file tags for \(filename)")
                }
                song.remoteFilename = filename
                songs.append(song)
            } else {
                let dbMeta = metadataMap[filename]
                var artData: Data?
                if let rel = dbMeta?.artworkRelativePath {
                    carryArtworkRelativePaths[filename] = rel
                    let semArt = DispatchSemaphore(value: 0)
                    self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/Artwork/Originals/\(rel)") { data in
                        artData = data
                        semArt.signal()
                    }
                    semArt.wait()
                    if let artData {
                        let artLocalURL = carryArtworkRoot.appendingPathComponent(rel)
                        let artDir = artLocalURL.deletingLastPathComponent()
                        try? fm.createDirectory(at: artDir, withIntermediateDirectories: true)
                        try? artData.write(to: artLocalURL)
                    }
                }
                let fallbackTitle = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                let fileSize = (try? fm.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? 0
                songs.append(
                    SongMetadata(
                        localURL: localURL,
                        title: dbMeta?.title ?? fallbackTitle,
                        artist: dbMeta?.artist ?? "Unknown Artist",
                        album: dbMeta?.album ?? "Unknown Album",
                        albumArtist: nil,
                        genre: dbMeta?.genre ?? "Music",
                        year: dbMeta?.year ?? Calendar.current.component(.year, from: Date()),
                        durationMs: dbMeta?.durationMs ?? 0,
                        fileSize: dbMeta?.fileSize ?? fileSize,
                        remoteFilename: filename,
                        artworkData: artData,
                        lyrics: dbMeta?.lyrics
                    )
                )
            }
        }
        
        return (songs, carryFilenames, carryArtworkRelativePaths, stagingDir)
    }
    
    private func mergeSongsIntoDeviceDatabase(_ songs: [SongMetadata]) -> Bool {
        guard !songs.isEmpty else { return true }
        
        var onDeviceFiles = Set<String>()
        let semFiles = DispatchSemaphore(value: 0)
        self.listFiles(remotePath: "/iTunes_Control/Music/F00") { files in
            if let files {
                onDeviceFiles = Set(files)
            }
            semFiles.signal()
        }
        semFiles.wait()
        
        let semDb = DispatchSemaphore(value: 0)
        var dbData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
            dbData = data
            semDb.signal()
        }
        semDb.wait()
        guard let dbData, dbData.count > 10000 else {
            Logger.shared.log("[Backup] Merge failed: current DB unavailable")
            return false
        }
        
        let semWal = DispatchSemaphore(value: 0)
        var walData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
            walData = data
            semWal.signal()
        }
        semWal.wait()
        
        let semShm = DispatchSemaphore(value: 0)
        var shmData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
            shmData = data
            semShm.signal()
        }
        semShm.wait()
        
        let mergedResult: (dbURL: URL, existingFiles: Set<String>, artworkInfo: [MediaLibraryBuilder.ArtworkInfo], pids: [Int64])
        do {
            mergedResult = try MediaLibraryBuilder.addSongsToExistingDatabase(
                existingDbData: dbData,
                walData: walData,
                shmData: shmData,
                newSongs: songs,
                existingOnDeviceFiles: onDeviceFiles,
                version: getDatabaseVersion()
            )
        } catch {
            Logger.shared.log("[Backup] Merge failed while building DB: \(error)")
            return false
        }
        
        let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
        let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
        let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
        let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
        
        let semUpload = DispatchSemaphore(value: 0)
        var uploaded = false
        self.uploadFileToDevice(localURL: mergedResult.dbURL, remotePath: tempDBPath) { ok in
            uploaded = ok
            semUpload.signal()
        }
        semUpload.wait()
        
        guard uploaded else {
            Logger.shared.log("[Backup] Merge failed: could not upload merged DB")
            return false
        }
        
        var afc: AfcClientHandle?
        self.connectAfcClient(&afc)
        guard let afc else {
            Logger.shared.log("[Backup] Merge failed: AFC unavailable for swap")
            return false
        }
        defer { afc_client_free(afc) }
        
        if !self.replaceRemoteMediaLibrary(
            tempDBPath: tempDBPath,
            finalDBPath: finalDBPath,
            shmPath: shmPath,
            walPath: walPath,
            afc: afc,
            logContext: "[Backup]"
        ) {
            Logger.shared.log("[Backup] Merge failed: atomic swap rename failed")
            return false
        }
        
        return true
    }
    
    private func stageCurrentMediaLibraryForMutation(label: String) -> (tempDir: URL, dbURL: URL, musicDir: String)? {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("\(label)_\(UUID().uuidString)", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb")

        let semDb = DispatchSemaphore(value: 0)
        var dbData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
            dbData = data
            semDb.signal()
        }
        semDb.wait()

        let semWal = DispatchSemaphore(value: 0)
        var walData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
            walData = data
            semWal.signal()
        }
        semWal.wait()

        let semShm = DispatchSemaphore(value: 0)
        var shmData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
            shmData = data
            semShm.signal()
        }
        semShm.wait()

        guard self.hasUsableExistingLibrary(dbData: dbData, walData: walData, shmData: shmData),
              let dbData else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try dbData.write(to: dbURL)
            if let walData, !walData.isEmpty {
                try walData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-wal"))
            }
            if let shmData, !shmData.isEmpty {
                try shmData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-shm"))
            }
        } catch {
            Logger.shared.log("[DeviceManager] Failed to stage MediaLibrary for \(label): \(error)")
            try? fileManager.removeItem(at: tempDir)
            return nil
        }

        return (tempDir, dbURL, self.resolvePrimaryMusicDirectory())
    }

    private func commitStagedMediaLibrary(localDbURL: URL) -> Bool {
        let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"

        let semUpload = DispatchSemaphore(value: 0)
        var uploaded = false
        self.uploadFileToDevice(localURL: localDbURL, remotePath: tempDBPath) { ok in
            uploaded = ok
            semUpload.signal()
        }
        semUpload.wait()

        guard uploaded else { return false }

        var afc: AfcClientHandle?
        self.connectAfcClient(&afc)
        guard let afc else { return false }
        defer { afc_client_free(afc) }

        return replaceRemoteMediaLibrary(tempDBPath: tempDBPath, afc: afc, logContext: "[DeviceManager]")
    }

    private func replaceRemoteMediaLibrary(
        tempDBPath: String = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp",
        finalDBPath: String = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb",
        shmPath: String = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm",
        walPath: String = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal",
        afc: AfcClientHandle,
        logContext: String
    ) -> Bool {
        let backupDBPath = finalDBPath + ".backup"

        _ = afc_remove_path(afc, shmPath)
        _ = afc_remove_path(afc, walPath)
        _ = afc_remove_path(afc, backupDBPath)

        var info = AfcFileInfo()
        let hasExistingFinal = afc_get_file_info(afc, finalDBPath, &info) == nil
        if hasExistingFinal {
            afc_file_info_free(&info)
        }

        if hasExistingFinal {
            let backupRenameErr = afc_rename_path(afc, finalDBPath, backupDBPath)
            if backupRenameErr != nil {
                Logger.shared.log("\(logContext) ERROR: Failed to move current database aside for protected swap")
                _ = afc_remove_path(afc, tempDBPath)
                return false
            }
        }

        let renameErr = afc_rename_path(afc, tempDBPath, finalDBPath)
        if renameErr == nil {
            if hasExistingFinal {
                _ = afc_remove_path(afc, backupDBPath)
            }
            return true
        }

        Logger.shared.log("\(logContext) ERROR: Failed to activate staged database")
        if hasExistingFinal {
            let restoreErr = afc_rename_path(afc, backupDBPath, finalDBPath)
            if restoreErr == nil {
                Logger.shared.log("\(logContext) Restored previous database after swap failure")
            } else {
                Logger.shared.log("\(logContext) ERROR: Failed to restore previous database after swap failure")
            }
        }
        _ = afc_remove_path(afc, tempDBPath)
        return false
    }

    private func itemPid(forRemoteFilename filename: String, db: OpaquePointer?) -> Int64? {
        var stmt: OpaquePointer?
        let sql = "SELECT item_pid FROM item_extra WHERE location = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if stmt != nil { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, filename, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func ensureNamedArtist(
        db: OpaquePointer?,
        tableName: String,
        idColumn: String,
        nameColumn: String,
        sortColumn: String,
        name: String,
        representativeItemPid: Int64
    ) -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        if let existing = self.firstInt64Query(
            db: db,
            sql: "SELECT \(idColumn) FROM \(tableName) WHERE lower(\(nameColumn)) = lower(?) LIMIT 1",
            text: trimmed
        ) {
            return existing
        }

        let nextId = self.firstInt64Query(db: db, sql: "SELECT IFNULL(MAX(\(idColumn)), 0) + 1 FROM \(tableName)") ?? 1
        let escaped = self.escapeSQLString(trimmed)
        _ = self.sqliteExec(db, """
        INSERT INTO \(tableName) (\(idColumn), \(nameColumn), \(sortColumn), representative_item_pid)
        VALUES (\(nextId), '\(escaped)', '\(escaped)', \(representativeItemPid))
        """)
        return nextId
    }

    private func ensureAlbum(
        db: OpaquePointer?,
        name: String,
        albumArtistPid: Int64,
        representativeItemPid: Int64,
        year: Int
    ) -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        if let existing = self.firstInt64Query(
            db: db,
            sql: "SELECT album_pid FROM album WHERE lower(album) = lower(?) AND album_artist_pid = \(albumArtistPid) LIMIT 1",
            text: trimmed
        ) {
            return existing
        }

        let nextId = self.firstInt64Query(db: db, sql: "SELECT IFNULL(MAX(album_pid), 0) + 1 FROM album") ?? 1
        let escaped = self.escapeSQLString(trimmed)
        _ = self.sqliteExec(db, """
        INSERT INTO album (album_pid, album, sort_album, album_artist_pid, representative_item_pid, album_year)
        VALUES (\(nextId), '\(escaped)', '\(escaped)', \(albumArtistPid), \(representativeItemPid), \(max(0, year)))
        """)
        return nextId
    }

    private func ensureGenre(db: OpaquePointer?, name: String, representativeItemPid: Int64) -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        if let existing = self.firstInt64Query(
            db: db,
            sql: "SELECT genre_id FROM genre WHERE lower(genre) = lower(?) LIMIT 1",
            text: trimmed
        ) {
            return existing
        }

        let nextId = self.firstInt64Query(db: db, sql: "SELECT IFNULL(MAX(genre_id), 0) + 1 FROM genre") ?? 1
        let escaped = self.escapeSQLString(trimmed)
        _ = self.sqliteExec(db, """
        INSERT INTO genre (genre_id, genre, representative_item_pid)
        VALUES (\(nextId), '\(escaped)', \(representativeItemPid))
        """)
        return nextId
    }

    private func firstInt64Query(db: OpaquePointer?, sql: String, text: String? = nil) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            if stmt != nil { sqlite3_finalize(stmt) }
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if let text {
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func escapeSQLString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func sqliteExec(_ db: OpaquePointer?, _ sql: String) -> Bool {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if rc != SQLITE_OK {
            if let msg = errorMsg {
                Logger.shared.log("[Backup] SQLite exec warning: \(String(cString: msg))")
                sqlite3_free(errorMsg)
            }
            return false
        }
        return true
    }
    
    private func mergeCarryOverRowsFromSourceDB(sourceDbURL: URL, carryFilenames: [String]) -> Bool {
        guard !carryFilenames.isEmpty else { return true }
        
        let semDb = DispatchSemaphore(value: 0)
        var dstDbData: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
            dstDbData = data
            semDb.signal()
        }
        semDb.wait()
        guard let dstDbData, dstDbData.count > 10000 else {
            Logger.shared.log("[Backup] Row-merge failed: destination DB unavailable")
            return false
        }
        
        let semWal = DispatchSemaphore(value: 0)
        var dstWal: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
            dstWal = data
            semWal.signal()
        }
        semWal.wait()
        
        let semShm = DispatchSemaphore(value: 0)
        var dstShm: Data?
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
            dstShm = data
            semShm.signal()
        }
        semShm.wait()
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("restore_rowmerge_\(UUID().uuidString)", isDirectory: true)
        let dstDbURL = tempDir.appendingPathComponent("MergedMediaLibrary.sqlitedb")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try dstDbData.write(to: dstDbURL)
            if let dstWal {
                try dstWal.write(to: tempDir.appendingPathComponent("MergedMediaLibrary.sqlitedb-wal"))
            }
            if let dstShm {
                try dstShm.write(to: tempDir.appendingPathComponent("MergedMediaLibrary.sqlitedb-shm"))
            }
        } catch {
            Logger.shared.log("[Backup] Row-merge staging failed: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        var db: OpaquePointer?
        guard sqlite3_open(dstDbURL.path, &db) == SQLITE_OK else {
            Logger.shared.log("[Backup] Row-merge failed: cannot open destination DB")
            return false
        }
        defer { sqlite3_close(db) }
        
        _ = sqliteExec(db, "PRAGMA foreign_keys=OFF")
        _ = sqliteExec(db, "ATTACH DATABASE '\(sourceDbURL.path.replacingOccurrences(of: "'", with: "''"))' AS src")
        _ = sqliteExec(db, "CREATE TEMP TABLE carry_filenames (filename TEXT PRIMARY KEY)")
        
        var insertLocStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO carry_filenames(filename) VALUES (?)", -1, &insertLocStmt, nil) == SQLITE_OK {
            for filename in carryFilenames {
                sqlite3_bind_text(insertLocStmt, 1, filename, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(insertLocStmt)
                sqlite3_reset(insertLocStmt)
                sqlite3_clear_bindings(insertLocStmt)
            }
        }
        if insertLocStmt != nil { sqlite3_finalize(insertLocStmt) }
        
        _ = sqliteExec(db, """
        CREATE TEMP TABLE src_pids AS
        SELECT DISTINCT ie.item_pid
        FROM src.item_extra ie
        JOIN carry_filenames cf
          ON ie.location = cf.filename
          OR ie.location LIKE '%/' || cf.filename
        """)
        _ = sqliteExec(db, """
        CREATE TEMP TABLE dst_pids AS
        SELECT DISTINCT ie.item_pid
        FROM item_extra ie
        JOIN carry_filenames cf
          ON ie.location = cf.filename
          OR ie.location LIKE '%/' || cf.filename
        """)
        
        for table in ["item","item_extra","item_playback","item_stats","item_store","item_video","item_search","lyrics","chapter"] {
            _ = sqliteExec(db, "DELETE FROM \(table) WHERE item_pid IN (SELECT item_pid FROM dst_pids)")
        }
        
        _ = sqliteExec(db, "INSERT OR REPLACE INTO sort_map SELECT * FROM src.sort_map")
        _ = sqliteExec(db, "INSERT OR REPLACE INTO item_artist SELECT * FROM src.item_artist WHERE item_artist_pid IN (SELECT DISTINCT item_artist_pid FROM src.item WHERE item_pid IN (SELECT item_pid FROM src_pids))")
        _ = sqliteExec(db, "INSERT OR REPLACE INTO album_artist SELECT * FROM src.album_artist WHERE album_artist_pid IN (SELECT DISTINCT album_artist_pid FROM src.item WHERE item_pid IN (SELECT item_pid FROM src_pids))")
        _ = sqliteExec(db, "INSERT OR REPLACE INTO album SELECT * FROM src.album WHERE album_pid IN (SELECT DISTINCT album_pid FROM src.item WHERE item_pid IN (SELECT item_pid FROM src_pids))")
        _ = sqliteExec(db, "INSERT OR REPLACE INTO genre SELECT * FROM src.genre WHERE genre_id IN (SELECT DISTINCT genre_id FROM src.item WHERE item_pid IN (SELECT item_pid FROM src_pids))")
        
        for table in ["item","item_extra","item_playback","item_stats","item_store","item_video","item_search","lyrics","chapter"] {
            _ = sqliteExec(db, "INSERT OR REPLACE INTO \(table) SELECT * FROM src.\(table) WHERE item_pid IN (SELECT item_pid FROM src_pids)")
        }
        
        _ = sqliteExec(db, "DELETE FROM artwork_token WHERE entity_pid IN (SELECT item_pid FROM dst_pids)")
        _ = sqliteExec(db, "DELETE FROM best_artwork_token WHERE entity_pid IN (SELECT item_pid FROM dst_pids)")
        _ = sqliteExec(db, "INSERT OR REPLACE INTO artwork_token SELECT * FROM src.artwork_token WHERE entity_pid IN (SELECT item_pid FROM src_pids)")
        _ = sqliteExec(db, "INSERT OR REPLACE INTO best_artwork_token SELECT * FROM src.best_artwork_token WHERE entity_pid IN (SELECT item_pid FROM src_pids)")
        
        _ = sqliteExec(db, """
        INSERT OR REPLACE INTO artwork
        SELECT * FROM src.artwork
        WHERE artwork_token IN (
            SELECT artwork_token FROM src.artwork_token WHERE entity_pid IN (SELECT item_pid FROM src_pids)
            UNION
            SELECT available_artwork_token FROM src.best_artwork_token WHERE entity_pid IN (SELECT item_pid FROM src_pids)
            UNION
            SELECT fetchable_artwork_token FROM src.best_artwork_token WHERE entity_pid IN (SELECT item_pid FROM src_pids)
        )
        """)
        
        _ = sqliteExec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        _ = sqliteExec(db, "PRAGMA journal_mode=DELETE")
        _ = sqliteExec(db, "DETACH DATABASE src")
        
        let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
        let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
        let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
        let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
        
        let semUpload = DispatchSemaphore(value: 0)
        var uploaded = false
        self.uploadFileToDevice(localURL: dstDbURL, remotePath: tempDBPath) { ok in
            uploaded = ok
            semUpload.signal()
        }
        semUpload.wait()
        guard uploaded else {
            Logger.shared.log("[Backup] Row-merge failed: upload merged DB failed")
            return false
        }
        
        var afc: AfcClientHandle?
        self.connectAfcClient(&afc)
        guard let afc else { return false }
        defer { afc_client_free(afc) }
        
        if !self.replaceRemoteMediaLibrary(
            tempDBPath: tempDBPath,
            finalDBPath: finalDBPath,
            shmPath: shmPath,
            walPath: walPath,
            afc: afc,
            logContext: "[Backup]"
        ) {
            Logger.shared.log("[Backup] Row-merge failed: atomic swap failed")
            return false
        }
        
        return true
    }
    
    func fetchDatabaseSnapshots(completion: @escaping ([DatabaseSnapshotInfo]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let root = self.snapshotsDirectoryURL
            
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                completion([])
                return
            }
            
            var snapshots: [DatabaseSnapshotInfo] = []
            for dir in entries where dir.hasDirectoryPath && dir.lastPathComponent.hasPrefix("snapshot_") {
                let dbURL = dir.appendingPathComponent("MediaLibrary.sqlitedb")
                guard fm.fileExists(atPath: dbURL.path) else { continue }
                
                let values = try? dir.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                let songCount = self.countSongsInSnapshotDB(dbURL)
                
                snapshots.append(
                    DatabaseSnapshotInfo(
                        folderName: dir.lastPathComponent,
                        createdAt: createdAt,
                        songCount: songCount
                    )
                )
            }
            
            snapshots.sort { $0.createdAt > $1.createdAt }
            completion(snapshots)
        }
    }

    func fetchExportableSongs(completion: @escaping ([ExportableSongInfo]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.ensureActiveTransport(reason: "loading the device library") else {
                completion([])
                return
            }

            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent("song_export_probe_\(UUID().uuidString)", isDirectory: true)

            defer { try? fileManager.removeItem(at: tempDir) }

            do {
                try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                Logger.shared.log("[Export] Failed to create staging directory: \(error)")
                completion([])
                return
            }

            let semDb = DispatchSemaphore(value: 0)
            var dbData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
                dbData = data
                semDb.signal()
            }
            semDb.wait()

            let semWal = DispatchSemaphore(value: 0)
            var walData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
                walData = data
                semWal.signal()
            }
            semWal.wait()

            let semShm = DispatchSemaphore(value: 0)
            var shmData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
                shmData = data
                semShm.signal()
            }
            semShm.wait()

            guard self.hasUsableExistingLibrary(dbData: dbData, walData: walData, shmData: shmData) else {
                Logger.shared.log(
                    "[Export] Failed to load usable MediaLibrary.sqlitedb for song export list " +
                    "(db=\(dbData?.count ?? 0), wal=\(walData?.count ?? 0), shm=\(shmData?.count ?? 0))"
                )
                completion([])
                return
            }

            guard let dbData else {
                Logger.shared.log("[Export] Missing primary MediaLibrary.sqlitedb data during export staging")
                completion([])
                return
            }

            let stagedDbURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb")
            do {
                try dbData.write(to: stagedDbURL)
                if let walData {
                    try walData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-wal"))
                }
                if let shmData {
                    try shmData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-shm"))
                }
            } catch {
                Logger.shared.log("[Export] Failed to stage export database files: \(error)")
                completion([])
                return
            }

            var onDeviceFiles = Set<String>()
            let musicDir = self.resolvePrimaryMusicDirectory()
            let semFiles = DispatchSemaphore(value: 0)
            self.listFiles(remotePath: musicDir) { files in
                if let files {
                    onDeviceFiles = Set(files)
                }
                semFiles.signal()
            }
            semFiles.wait()

            let metadataMap = self.carrySongMetadataMapFromDatabase(stagedDbURL)
            let songs = self.musicFilenamesFromDatabase(stagedDbURL)
                .filter { onDeviceFiles.contains($0) }
                .map { filename -> ExportableSongInfo in
                    let meta = metadataMap[filename]
                    let fallbackTitle = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                    return ExportableSongInfo(
                        itemPid: meta?.itemPid ?? 0,
                        remoteFilename: filename,
                        title: meta?.title ?? fallbackTitle,
                        artist: meta?.artist ?? "Unknown Artist",
                        album: meta?.album ?? "Unknown Album",
                        genre: meta?.genre ?? "Music",
                        year: meta?.year ?? 0,
                        durationMs: meta?.durationMs ?? 0,
                        fileSize: meta?.fileSize ?? 0,
                        trackNumber: meta?.trackNumber,
                        lyrics: meta?.lyrics,
                        explicitRating: meta?.explicitRating ?? 0,
                        fileExtension: URL(fileURLWithPath: filename).pathExtension,
                        artworkRelativePath: meta?.artworkRelativePath
                    )
                }
                .sorted {
                    if $0.artist == $1.artist {
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                    return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
                }

            Logger.shared.log("[Export] Found \(songs.count) exportable songs")
            completion(songs)
        }
    }

    private func uniqueExportDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("device-song-exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func exportSongsToTemporaryDirectory(_ songs: [ExportableSongInfo], completion: @escaping (Bool, String, [URL]) -> Void) {
        let exportDirectory = uniqueExportDirectory()
        exportSongs(songs, destinationFolder: exportDirectory, completion: completion)
    }

    func exportSongs(_ songs: [ExportableSongInfo], destinationFolder: URL, completion: @escaping (Bool, String, [URL]) -> Void) {
        guard !songs.isEmpty else {
            completion(false, "No songs selected.", [])
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard self.ensureActiveTransport(reason: "exporting songs from the device library") else {
                completion(false, "Could not reconnect to the device.", [])
                return
            }

            let fileManager = FileManager.default
            let exportDirectory = destinationFolder

            do {
                if !fileManager.fileExists(atPath: exportDirectory.path) {
                    try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
                }
            } catch {
                Logger.shared.log("[Export] Failed to create export folder: \(error)")
                completion(false, "Could not access selected folder.", [])
                return
            }

            let musicDir = self.resolvePrimaryMusicDirectory()
            var exportedURLs: [URL] = []
            var usedNames = Set<String>()
            var failedCount = 0

            func destinationURL(for song: ExportableSongInfo) -> URL {
                let ext = song.fileExtension.isEmpty ? "mp3" : song.fileExtension
                let baseName = Self.sanitizedExportFilenameBase("\(song.artist) - \(song.title)")
                var candidate = "\(baseName).\(ext)"
                var suffix = 1
                while usedNames.contains(candidate) {
                    candidate = "\(baseName)-\(suffix).\(ext)"
                    suffix += 1
                }
                usedNames.insert(candidate)
                return exportDirectory.appendingPathComponent(candidate)
            }

            func exportNext(_ index: Int) {
                guard index < songs.count else {
                    let success = !exportedURLs.isEmpty
                    let message: String
                    if success {
                        message = failedCount == 0
                            ? "Exported \(exportedURLs.count) song(s)."
                            : "Exported \(exportedURLs.count) song(s), \(failedCount) failed."
                    } else {
                        message = "No songs were exported."
                    }
                    completion(success, message, exportedURLs)
                    return
                }

                let song = songs[index]
                let localURL = destinationURL(for: song)
                if fileManager.fileExists(atPath: localURL.path) {
                    try? fileManager.removeItem(at: localURL)
                }

                let remotePath = "\(musicDir)/\(song.remoteFilename)"
                self.downloadFileFromDevice(remotePath: remotePath, localURL: localURL) { success in
                    if success {
                        exportedURLs.append(localURL)
                    } else {
                        failedCount += 1
                        Logger.shared.log("[Export] Failed to export \(song.remoteFilename)")
                    }
                    exportNext(index + 1)
                }
            }

            exportNext(0)
        }
    }

    func deleteExportableSong(_ song: ExportableSongInfo, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.ensureActiveTransport(reason: "deleting a song from the device library") else {
                completion(false, "Device connection unavailable.")
                return
            }

            guard let context = self.stageCurrentMediaLibraryForMutation(label: "delete_song") else {
                completion(false, "Could not stage MediaLibrary.sqlitedb.")
                return
            }
            defer { try? FileManager.default.removeItem(at: context.tempDir) }

            let remotePath = "\(context.musicDir)/\(song.remoteFilename)"
            let deleteSem = DispatchSemaphore(value: 0)
            var remoteDeleted = false
            self.removeFileFromDevice(remotePath: remotePath) { ok in
                remoteDeleted = ok
                deleteSem.signal()
            }
            deleteSem.wait()

            guard remoteDeleted else {
                completion(false, "Failed to remove the song file from the device.")
                return
            }

            var db: OpaquePointer?
            guard sqlite3_open(context.dbURL.path, &db) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                completion(false, "Could not open MediaLibrary.sqlitedb.")
                return
            }

            let itemPid = song.itemPid > 0 ? song.itemPid : (self.itemPid(forRemoteFilename: song.remoteFilename, db: db) ?? 0)
            guard itemPid > 0 else {
                sqlite3_close(db)
                completion(false, "Could not find that song in MediaLibrary.sqlitedb.")
                return
            }

            _ = self.sqliteExec(db, "BEGIN IMMEDIATE TRANSACTION")
            let success = [
                "DELETE FROM item WHERE item_pid = \(itemPid)",
                "DELETE FROM item_extra WHERE item_pid = \(itemPid)",
                "DELETE FROM item_playback WHERE item_pid = \(itemPid)",
                "DELETE FROM item_stats WHERE item_pid = \(itemPid)",
                "DELETE FROM item_store WHERE item_pid = \(itemPid)",
                "DELETE FROM item_video WHERE item_pid = \(itemPid)",
                "DELETE FROM item_search WHERE item_pid = \(itemPid)",
                "DELETE FROM lyrics WHERE item_pid = \(itemPid)",
                "DELETE FROM chapter WHERE item_pid = \(itemPid)",
                "DELETE FROM artwork_token WHERE entity_pid = \(itemPid)",
                "DELETE FROM best_artwork_token WHERE entity_pid = \(itemPid)"
            ].allSatisfy { self.sqliteExec(db, $0) }
            _ = self.sqliteExec(db, success ? "COMMIT" : "ROLLBACK")
            _ = self.sqliteExec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = self.sqliteExec(db, "PRAGMA journal_mode=DELETE")
            sqlite3_close(db)

            guard success else {
                completion(false, "Could not update MediaLibrary.sqlitedb.")
                return
            }

            guard self.commitStagedMediaLibrary(localDbURL: context.dbURL) else {
                completion(false, "Failed to upload the updated device library.")
                return
            }

            completion(true, "Deleted \(song.title).")
        }
    }

    func updateExportableSongMetadata(
        original: ExportableSongInfo,
        updatedSong: SongMetadata,
        completion: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard self.ensureActiveTransport(reason: "editing song metadata on the device") else {
                completion(false, "Device connection unavailable.")
                return
            }

            let killed = self.terminateMusicAppIfRunning()
            Logger.shared.log("[SyncLifecycle] Music pre-kill \(killed ? "completed" : "skipped/failed")")

            guard let context = self.stageCurrentMediaLibraryForMutation(label: "edit_song") else {
                completion(false, "Could not stage MediaLibrary.sqlitedb.")
                return
            }
            defer { try? FileManager.default.removeItem(at: context.tempDir) }

            var db: OpaquePointer?
            guard sqlite3_open(context.dbURL.path, &db) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                completion(false, "Could not open MediaLibrary.sqlitedb.")
                return
            }

            let itemPid = original.itemPid > 0 ? original.itemPid : (self.itemPid(forRemoteFilename: original.remoteFilename, db: db) ?? 0)
            guard itemPid > 0 else {
                sqlite3_close(db)
                completion(false, "Could not find that song in MediaLibrary.sqlitedb.")
                return
            }

            let safeTitle = updatedSong.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.title : updatedSong.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeArtist = updatedSong.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.artist : updatedSong.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeAlbum = updatedSong.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.album : updatedSong.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeGenre = updatedSong.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.genre : updatedSong.genre.trimmingCharacters(in: .whitespacesAndNewlines)

            let newArtistPid = self.ensureNamedArtist(
                db: db,
                tableName: "item_artist",
                idColumn: "item_artist_pid",
                nameColumn: "item_artist",
                sortColumn: "sort_item_artist",
                name: safeArtist,
                representativeItemPid: itemPid
            )
            let newAlbumArtistPid = self.ensureNamedArtist(
                db: db,
                tableName: "album_artist",
                idColumn: "album_artist_pid",
                nameColumn: "album_artist",
                sortColumn: "sort_album_artist",
                name: safeArtist,
                representativeItemPid: itemPid
            )
            let newAlbumPid = self.ensureAlbum(
                db: db,
                name: safeAlbum,
                albumArtistPid: newAlbumArtistPid,
                representativeItemPid: itemPid,
                year: updatedSong.year > 0 ? updatedSong.year : original.year
            )
            let newGenreId = self.ensureGenre(
                db: db,
                name: safeGenre,
                representativeItemPid: itemPid
            )

            _ = self.sqliteExec(db, "BEGIN IMMEDIATE TRANSACTION")

            let escapedTitle = self.escapeSQLString(safeTitle)
            let escapedArtist = self.escapeSQLString(safeArtist)
            let escapedAlbum = self.escapeSQLString(safeAlbum)
            let escapedGenre = self.escapeSQLString(safeGenre)
            let escapedLyrics = self.escapeSQLString((updatedSong.lyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            let trackNumber = max(0, updatedSong.trackNumber ?? original.trackNumber ?? 0)
            let year = max(0, updatedSong.year)
            let explicitRating = max(0, updatedSong.explicitRating)

            let success = [
                """
                UPDATE item
                SET item_artist_pid = \(newArtistPid),
                    album_pid = \(newAlbumPid),
                    album_artist_pid = \(newAlbumArtistPid),
                    genre_id = \(newGenreId),
                    track_number = \(trackNumber)
                WHERE item_pid = \(itemPid)
                """,
                """
                UPDATE item_extra
                SET title = '\(escapedTitle)',
                    sort_title = '\(escapedTitle)',
                    year = \(year),
                    content_rating = \(explicitRating)
                WHERE item_pid = \(itemPid)
                """,
                """
                UPDATE album
                SET album = '\(escapedAlbum)',
                    sort_album = '\(escapedAlbum)',
                    album_year = CASE WHEN \(year) > 0 THEN \(year) ELSE album_year END
                WHERE album_pid = \(newAlbumPid)
                """,
                """
                UPDATE item_artist
                SET item_artist = '\(escapedArtist)',
                    sort_item_artist = '\(escapedArtist)'
                WHERE item_artist_pid = \(newArtistPid)
                """,
                """
                UPDATE album_artist
                SET album_artist = '\(escapedArtist)',
                    sort_album_artist = '\(escapedArtist)'
                WHERE album_artist_pid = \(newAlbumArtistPid)
                """,
                """
                UPDATE genre
                SET genre = '\(escapedGenre)'
                WHERE genre_id = \(newGenreId)
                """,
                """
                INSERT OR REPLACE INTO lyrics (item_pid, lyrics, store_lyrics_available, time_synced_lyrics_available)
                VALUES (\(itemPid), '\(escapedLyrics)', 1, 1)
                """
            ].allSatisfy { self.sqliteExec(db, $0) }

            _ = self.sqliteExec(db, success ? "COMMIT" : "ROLLBACK")
            _ = self.sqliteExec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = self.sqliteExec(db, "PRAGMA journal_mode=DELETE")
            sqlite3_close(db)

            guard success else {
                completion(false, "Could not update MediaLibrary.sqlitedb.")
                return
            }

            if let artworkData = updatedSong.artworkData,
               !artworkData.isEmpty,
               let relativePath = original.artworkRelativePath,
               !relativePath.isEmpty {
                var afc: AfcClientHandle?
                self.connectAfcClient(&afc)
                if let afc {
                    let remoteArtworkPath = "/iTunes_Control/iTunes/Artwork/Originals/\(relativePath)"
                    _ = self.uploadDataToDevice(artworkData, remotePath: remoteArtworkPath, afc: afc, verify: false)
                    afc_client_free(afc)
                }
            }

            guard self.commitStagedMediaLibrary(localDbURL: context.dbURL) else {
                completion(false, "Failed to upload the updated device library.")
                return
            }

            completion(true, "Updated metadata for \(safeTitle).")
        }
    }
    
    private func resolvePrimaryMusicDirectory() -> String {
        let fallback = "/iTunes_Control/Music/F00"
        var dbData: Data?
        var walData: Data?
        var shmData: Data?

        let sem = DispatchSemaphore(value: 0)
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
            dbData = data
            sem.signal()
        }
        sem.wait()

        let semWal = DispatchSemaphore(value: 0)
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
            walData = data
            semWal.signal()
        }
        semWal.wait()

        let semShm = DispatchSemaphore(value: 0)
        self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
            shmData = data
            semShm.signal()
        }
        semShm.wait()

        guard dbData != nil else {
            Logger.shared.log("[DeviceManager] Music dir resolve: fallback to \(fallback) (no DB)")
            return fallback
        }

        let resolved: String? = withStagedMediaLibrary(dbData: dbData, walData: walData, shmData: shmData, label: "music_dir_probe") { dbURL in
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                return nil
            }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            let sql = "SELECT path FROM base_location WHERE base_location_id = 3840 LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if stmt != nil { sqlite3_finalize(stmt) }
                return nil
            }
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_step(stmt) == SQLITE_ROW, let pathPtr = sqlite3_column_text(stmt, 0) else {
                return nil
            }

            let rawPath = String(cString: pathPtr)
            let normalized = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
            return normalized.hasPrefix("/iTunes_Control/Music/") ? normalized : nil
        }

        if let resolved {
            Logger.shared.log("[DeviceManager] Music dir resolved from base_location(3840): \(resolved)")
            return resolved
        }

        Logger.shared.log("[DeviceManager] Music dir resolve: fallback to \(fallback) (base_location missing/invalid)")
        return fallback
    }

    private func withStagedMediaLibrary<T>(
        dbData: Data?,
        walData: Data?,
        shmData: Data?,
        label: String,
        _ body: (URL) -> T?
    ) -> T? {
        guard let dbData, !dbData.isEmpty else { return nil }

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("\(label)_\(UUID().uuidString)", isDirectory: true)
        let dbURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb")
        let walURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb-wal")
        let shmURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb-shm")

        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try dbData.write(to: dbURL)
            if let walData, !walData.isEmpty {
                try walData.write(to: walURL)
            }
            if let shmData, !shmData.isEmpty {
                try shmData.write(to: shmURL)
            }
            let result = body(dbURL)
            try? fileManager.removeItem(at: tempDir)
            return result
        } catch {
            Logger.shared.log("[DeviceManager] Failed to stage media library for \(label): \(error)")
            try? fileManager.removeItem(at: tempDir)
            return nil
        }
    }

    private func hasUsableExistingLibrary(dbData: Data?, walData: Data?, shmData: Data?) -> Bool {
        withStagedMediaLibrary(dbData: dbData, walData: walData, shmData: shmData, label: "library_probe") { dbURL in
            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                return false
            }
            defer { sqlite3_close(db) }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sqlite_master", -1, &stmt, nil) == SQLITE_OK else {
                if stmt != nil { sqlite3_finalize(stmt) }
                return false
            }
            defer { sqlite3_finalize(stmt) }

            return sqlite3_step(stmt) == SQLITE_ROW
        } ?? false
    }
    
    private func cleanUpOrphanedFiles(validFilenames: Set<String>, musicDir: String, completion: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            self.connectAfcClient(&afc)
            
            guard afc != nil else {
                Logger.shared.log("[DeviceManager] GC: Failed to connect AFC")
                completion(0)
                return
            }
            
            var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            var count: Int = 0
            
            let err = afc_list_directory(afc, musicDir, &entries, &count)
            
            var deletedCount = 0
            
            if err == nil, let list = entries {
                for i in 0..<count {
                    if let ptr = list[i] {
                        let filename = String(cString: ptr)
                        if filename != "." && filename != ".." {
                            if !validFilenames.contains(filename) {
                                let path = "\(musicDir)/\(filename)"
                                Logger.shared.log("[DeviceManager] GC: Deleting orphan -> \(filename)")
                                afc_remove_path(afc, path)
                                deletedCount += 1
                            }
                        }
                    }
                }
                free(entries)
            }
            
            afc_client_free(afc)
            completion(deletedCount)
        }
    }
    
    private func writeDownloadedData(_ data: Data, to localURL: URL) throws {
        let parentDirectory = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: localURL, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    func downloadFileFromDevice(remotePath: String, localURL: URL, completion: @escaping (Bool) -> Void) {
        self.downloadFileFromDevice(remotePath: remotePath) { data in
            guard let data = data else {
                completion(false)
                return
            }
            do {
                try self.writeDownloadedData(data, to: localURL)
                completion(true)
            } catch {
                Logger.shared.log("[DeviceManager] Error writing downloaded file: \(error)")
                completion(false)
            }
        }
    }

    func repairIOS26ArtworkColors(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        guard supportsIOS26ArtworkRepair else {
            completion(false, "This repair is only needed on iOS 26.4 or newer.")
            return
        }

        guard hasValidExpectedPairingFile else {
            completion(false, "Import your RP Pairing File first.")
            return
        }

        let startRepair = {
            self.runIOS26ArtworkRepair(progress: progress, completion: completion)
        }

        if heartbeatReady && hasActiveTransport {
            startRepair()
        } else {
            startHeartbeat { connected in
                guard connected else {
                    completion(false, "Could not connect to the device.")
                    return
                }
                startRepair()
            }
        }
    }

    func repairExperimentalAlbumArtworkPointers(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        guard hasValidExpectedPairingFile else {
            completion(false, "Import your RP Pairing File first.")
            return
        }

        artworkRepairCancelled = false

        let startRepair = {
            self.runExperimentalAlbumArtworkPointerRepair(progress: progress, completion: completion)
        }

        if heartbeatReady && hasActiveTransport {
            startRepair()
        } else {
            startHeartbeat { connected in
                // User may have cancelled while we were reconnecting
                if self.artworkRepairCancelled {
                    self.artworkRepairCancelled = false
                    completion(false, "Repair cancelled.")
                    return
                }
                guard connected else {
                    completion(false, "Could not connect to the device.")
                    return
                }
                startRepair()
            }
        }
    }

    private func runIOS26ArtworkRepair(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if self.killMusicBeforeInjectEnabled {
                let killed = self.terminateMusicAppIfRunning()
                Logger.shared.log("[ArtworkRepair] Music pre-kill \(killed ? "completed" : "skipped/failed")")
            }

            progress("Downloading MediaLibrary...")

            let semDb = DispatchSemaphore(value: 0)
            var dbData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
                dbData = data
                semDb.signal()
            }
            semDb.wait()

            guard let dbData, dbData.count > 10000 else {
                completion(false, "MediaLibrary.sqlitedb unavailable.")
                return
            }

            let semWal = DispatchSemaphore(value: 0)
            var walData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
                walData = data
                semWal.signal()
            }
            semWal.wait()

            let semShm = DispatchSemaphore(value: 0)
            var shmData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
                shmData = data
                semShm.signal()
            }
            semShm.wait()

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("artwork_repair_\(UUID().uuidString)", isDirectory: true)
            let dbURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb")

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try dbData.write(to: dbURL)
                if let walData {
                    try walData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-wal"))
                }
                if let shmData {
                    try shmData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-shm"))
                }
            } catch {
                Logger.shared.log("[ArtworkRepair] Staging failed: \(error)")
                completion(false, "Could not stage the database.")
                return
            }

            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not open the database.")
                return
            }

            _ = self.sqliteExec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = self.sqliteExec(db, "PRAGMA journal_mode=DELETE")
            let candidates = self.ios26ArtworkRepairCandidates(db: db)
            sqlite3_close(db)

            guard !candidates.isEmpty else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "No Apple Music matched artwork found.")
                return
            }

            Logger.shared.log("[ArtworkRepair] Found \(candidates.count) artwork candidates")

            // Check before starting the (potentially long) loop
            if self.artworkRepairCancelled {
                self.artworkRepairCancelled = false
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Repair cancelled.")
                return
            }

            Task { @MainActor in
                var repairs: [(ArtworkRepairCandidate, String)] = []
                var colorCache: [Int64: String] = [:]

                for (index, candidate) in candidates.enumerated() {
                    // Check at the start of every iteration
                    if self.artworkRepairCancelled {
                        self.artworkRepairCancelled = false
                        try? FileManager.default.removeItem(at: tempDir)
                        completion(false, "Repair cancelled.")
                        return
                    }

                    progress("Fetching artwork colors \(index + 1)/\(candidates.count)...")

                    if candidate.storeItemId > 0, let cached = colorCache[candidate.storeItemId] {
                        repairs.append((candidate, cached))
                        continue
                    }

                    let matchedSong: AppleMusicAPI.AppleMusicSong?
                    if candidate.storeItemId > 0 {
                        matchedSong = await AppleMusicAPI.shared.fetchSong(id: String(candidate.storeItemId))
                    } else {
                        matchedSong = await self.bestAppleMusicArtworkFallbackMatch(for: candidate)
                    }

                    guard let song = matchedSong,
                          let colors = song.attributes.artwork?.colors else {
                        if candidate.storeItemId > 0 {
                            Logger.shared.log("[ArtworkRepair] No Apple colors for store_item_id=\(candidate.storeItemId)")
                        } else {
                            Logger.shared.log("[ArtworkRepair] No Apple Music artwork colors available for fallback candidate \(candidate.artist) - \(candidate.title)")
                        }
                        continue
                    }

                    let colorAnalysis = MediaLibraryBuilder.colorAnalysisJSON(for: colors)
                    if let matchedStoreId = Int64(song.id), matchedStoreId > 0 {
                        colorCache[matchedStoreId] = colorAnalysis
                    }
                    repairs.append((candidate, colorAnalysis))
                }

                guard !repairs.isEmpty else {
                    try? FileManager.default.removeItem(at: tempDir)
                    completion(false, "No artwork colors were available from Apple Music.")
                    return
                }

                self.finishIOS26ArtworkRepair(
                    dbURL: dbURL,
                    tempDir: tempDir,
                    repairs: repairs,
                    progress: progress,
                    completion: completion
                )
            }
        }
    }

    private func runExperimentalAlbumArtworkPointerRepair(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if self.killMusicBeforeInjectEnabled {
                let killed = self.terminateMusicAppIfRunning()
                Logger.shared.log("[AlbumArtworkRepair] Music pre-kill \(killed ? "completed" : "skipped/failed")")
            }

            progress("Downloading MediaLibrary...")

            let semDb = DispatchSemaphore(value: 0)
            var dbData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
                dbData = data
                semDb.signal()
            }
            semDb.wait()

            guard let dbData, dbData.count > 10000 else {
                completion(false, "MediaLibrary.sqlitedb unavailable.")
                return
            }

            let semWal = DispatchSemaphore(value: 0)
            var walData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
                walData = data
                semWal.signal()
            }
            semWal.wait()

            let semShm = DispatchSemaphore(value: 0)
            var shmData: Data?
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
                shmData = data
                semShm.signal()
            }
            semShm.wait()

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("album_artwork_repair_\(UUID().uuidString)", isDirectory: true)
            let dbURL = tempDir.appendingPathComponent("MediaLibrary.sqlitedb")

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try dbData.write(to: dbURL)
                if let walData {
                    try walData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-wal"))
                }
                if let shmData {
                    try shmData.write(to: tempDir.appendingPathComponent("MediaLibrary.sqlitedb-shm"))
                }
            } catch {
                Logger.shared.log("[AlbumArtworkRepair] Staging failed: \(error)")
                completion(false, "Could not stage the database.")
                return
            }

            var db: OpaquePointer?
            guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not open the database.")
                return
            }

            _ = self.sqliteExec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = self.sqliteExec(db, "PRAGMA journal_mode=DELETE")
            let candidates = self.ios26ArtworkRepairCandidates(db: db)
            sqlite3_close(db)

            guard !candidates.isEmpty else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "No songs were available for experimental metadata refresh.")
                return
            }

            Logger.shared.log("[AlbumArtworkRepair] Found \(candidates.count) song candidates for metadata refresh")

            // Check before starting the (potentially long) loop
            if self.artworkRepairCancelled {
                self.artworkRepairCancelled = false
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Repair cancelled.")
                return
            }

            Task {
                var repairs: [ExperimentalAppleMetadataRepair] = []

                for (index, candidate) in candidates.enumerated() {
                    if self.artworkRepairCancelled {
                        self.artworkRepairCancelled = false
                        completion(false, "Repair cancelled.")
                        return
                    }

                    progress("Refreshing Apple metadata \(index + 1)/\(candidates.count)...")

                    let matchedSong: AppleMusicAPI.AppleMusicSong?
                    if candidate.storeItemId > 0 {
                        matchedSong = await AppleMusicAPI.shared.fetchSong(id: String(candidate.storeItemId))
                    } else {
                        matchedSong = await self.bestAppleMusicArtworkFallbackMatch(for: candidate)
                    }

                    guard let matchedSong,
                          let repair = await self.experimentalAppleMetadataRepair(for: candidate, matchedSong: matchedSong) else {
                        continue
                    }

                    repairs.append(repair)
                }

                guard !repairs.isEmpty else {
                    try? FileManager.default.removeItem(at: tempDir)
                    completion(false, "No confident Apple Music metadata matches were found.")
                    return
                }

                let finalizedRepairs = repairs

                await MainActor.run {
                    self.finishExperimentalAlbumArtworkPointerRepair(
                        dbURL: dbURL,
                        tempDir: tempDir,
                        repairs: finalizedRepairs,
                        progress: progress,
                        completion: completion
                    )
                }
            }
        }
    }

    private func finishExperimentalAlbumArtworkPointerRepair(
        dbURL: URL,
        tempDir: URL,
        repairs: [ExperimentalAppleMetadataRepair],
        progress: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            progress("Refreshing metadata and artwork...")

            var repairDb: OpaquePointer?
            guard sqlite3_open(dbURL.path, &repairDb) == SQLITE_OK else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not reopen the database.")
                return
            }

            let repairedCount = self.applyExperimentalAppleMetadataRepairs(db: repairDb, repairs: repairs, progress: progress)
            _ = self.sqliteExec(repairDb, "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = self.sqliteExec(repairDb, "PRAGMA journal_mode=DELETE")
            sqlite3_close(repairDb)

            guard repairedCount > 0 else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Advanced artwork and metadata fix failed.")
                return
            }

            let uploadedArtworkCount = self.uploadExperimentalArtworkFiles(repairs: repairs, progress: progress)
            progress("Uploading repaired database...")

            let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
            let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
            let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
            let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"

            let semUpload = DispatchSemaphore(value: 0)
            var uploaded = false
            self.uploadFileToDevice(localURL: dbURL, remotePath: tempDBPath) { ok in
                uploaded = ok
                semUpload.signal()
            }
            semUpload.wait()

            guard uploaded else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not upload the repaired database.")
                return
            }

            var afc: AfcClientHandle?
            self.connectAfcClient(&afc)
            guard let afc else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "AFC unavailable for database swap.")
                return
            }

            if !self.replaceRemoteMediaLibrary(
                tempDBPath: tempDBPath,
                finalDBPath: finalDBPath,
                shmPath: shmPath,
                walPath: walPath,
                afc: afc,
                logContext: "[AlbumArtworkRepair]"
            ) {
                afc_client_free(afc)
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not swap the repaired database.")
                return
            }

            afc_client_free(afc)
            try? FileManager.default.removeItem(at: tempDir)

            self.sendSyncFinishedNotification()
            Logger.shared.log("[AlbumArtworkRepair] Refreshed \(repairedCount) songs and uploaded \(uploadedArtworkCount) artwork files")
            completion(true, "Advanced artwork and metadata fix refreshed \(repairedCount) songs and \(uploadedArtworkCount) artwork files. Restart Music if it is still cached.")
        }
    }

    private func finishIOS26ArtworkRepair(
        dbURL: URL,
        tempDir: URL,
        repairs: [(ArtworkRepairCandidate, String)],
        progress: @escaping (String) -> Void,
        completion: @escaping (Bool, String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            progress("Updating artwork database...")

            var repairDb: OpaquePointer?
            guard sqlite3_open(dbURL.path, &repairDb) == SQLITE_OK else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not reopen the database.")
                return
            }

            let repairedCount = self.applyIOS26ArtworkRepairs(db: repairDb, repairs: repairs)
            _ = self.sqliteExec(repairDb, "PRAGMA wal_checkpoint(TRUNCATE)")
            _ = self.sqliteExec(repairDb, "PRAGMA journal_mode=DELETE")
            sqlite3_close(repairDb)

            guard repairedCount > 0 else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Artwork database update failed.")
                return
            }

            progress("Uploading repaired database...")

            let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
            let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
            let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
            let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"

            let semUpload = DispatchSemaphore(value: 0)
            var uploaded = false
            self.uploadFileToDevice(localURL: dbURL, remotePath: tempDBPath) { ok in
                uploaded = ok
                semUpload.signal()
            }
            semUpload.wait()

            guard uploaded else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not upload the repaired database.")
                return
            }

            var afc: AfcClientHandle?
            self.connectAfcClient(&afc)
            guard let afc else {
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "AFC unavailable for database swap.")
                return
            }

            if !self.replaceRemoteMediaLibrary(
                tempDBPath: tempDBPath,
                finalDBPath: finalDBPath,
                shmPath: shmPath,
                walPath: walPath,
                afc: afc,
                logContext: "[ArtworkRepair]"
            ) {
                afc_client_free(afc)
                try? FileManager.default.removeItem(at: tempDir)
                completion(false, "Could not swap the repaired database.")
                return
            }

            afc_client_free(afc)
            try? FileManager.default.removeItem(at: tempDir)

            self.sendSyncFinishedNotification()
            Logger.shared.log("[ArtworkRepair] Repaired \(repairedCount) artwork rows")
            completion(true, "Fixed artwork for \(repairedCount) songs. Restart Music if it is still cached.")
        }
    }

    private func normalizedArtworkRepairValue(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bestAppleMusicArtworkFallbackMatch(for candidate: ArtworkRepairCandidate) async -> AppleMusicAPI.AppleMusicSong? {
        let query = "\(candidate.artist) \(candidate.title)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        let results = await AppleMusicAPI.shared.searchSongs(query: query, limit: 5)
        guard !results.isEmpty else {
            Logger.shared.log("[ArtworkRepair] No Apple Music search results for fallback query: \(query)")
            return nil
        }

        let normalizedTitle = normalizedArtworkRepairValue(candidate.title)
        let normalizedArtist = normalizedArtworkRepairValue(candidate.artist)
        let normalizedAlbum = normalizedArtworkRepairValue(candidate.album)

        var bestSong: AppleMusicAPI.AppleMusicSong?
        var bestScore = Int.min

        for song in results {
            let songTitle = normalizedArtworkRepairValue(song.attributes.name)
            let songArtist = normalizedArtworkRepairValue(song.attributes.artistName)
            let songAlbum = normalizedArtworkRepairValue(song.attributes.albumName ?? "")

            var score = 0

            if !normalizedTitle.isEmpty {
                if songTitle == normalizedTitle {
                    score += 6
                } else if songTitle.contains(normalizedTitle) || normalizedTitle.contains(songTitle) {
                    score += 3
                }
            }

            if !normalizedArtist.isEmpty, normalizedArtist != "unknown artist" {
                if songArtist == normalizedArtist {
                    score += 5
                } else if songArtist.contains(normalizedArtist) || normalizedArtist.contains(songArtist) {
                    score += 2
                }
            }

            if !normalizedAlbum.isEmpty, normalizedAlbum != "unknown album" {
                if songAlbum == normalizedAlbum {
                    score += 2
                } else if songAlbum.contains(normalizedAlbum) || normalizedAlbum.contains(songAlbum) {
                    score += 1
                }
            }

            if bestSong == nil || score > bestScore {
                bestSong = song
                bestScore = score
            }
        }

        guard let bestSong, bestScore >= 7 else {
            Logger.shared.log("[ArtworkRepair] Fallback search did not find a confident Apple Music match for \(candidate.artist) - \(candidate.title)")
            return nil
        }

        Logger.shared.log("[ArtworkRepair] Fallback matched \(candidate.artist) - \(candidate.title) to Apple Music id=\(bestSong.id) with score=\(bestScore)")
        return bestSong
    }

    private func experimentalAppleMetadataRepair(
        for candidate: ArtworkRepairCandidate,
        matchedSong: AppleMusicAPI.AppleMusicSong
    ) async -> ExperimentalAppleMetadataRepair? {
        guard let storeItemId = Int64(matchedSong.id), storeItemId > 0 else {
            return nil
        }

        let title = matchedSong.attributes.name
        let artist = matchedSong.attributes.artistName
        let album = matchedSong.attributes.albumName ?? candidate.album
        let audioTraits = matchedSong.attributes.audioTraits ?? []
        let storeFlavor = Array(Set(audioTraits))
            .sorted()
            .joined(separator: ",")

        let artistId = matchedSong.relationships?.artists?.data.first.flatMap { Int64($0.id) } ?? 0
        let composerId = matchedSong.relationships?.composers?.data.first.flatMap { Int64($0.id) } ?? 0
        let genreStoreId = matchedSong.relationships?.genres?.data.first.flatMap { Int64($0.id) } ?? 0
        let albumStoreId = matchedSong.relationships?.albums?.data.first.flatMap { Int64($0.id) } ?? 0
        let releaseDateString = matchedSong.attributes.releaseDate ?? matchedSong.relationships?.albums?.data.first?.attributes.releaseDate
        let year = releaseDateString.flatMap { Int($0.prefix(4)) } ?? 0
        let releaseDate = releaseDateString.flatMap { SongMetadata.parseDateToEpoch($0) } ?? 0
        let explicitRating: Int
        if let rating = matchedSong.attributes.contentRating {
            explicitRating = (rating == "explicit") ? 1 : (rating == "clean" ? 2 : 0)
        } else {
            explicitRating = 0
        }

        let storefrontId = self.storefrontIDForCurrentRegion()
        let copyright = matchedSong.relationships?.albums?.data.first?.attributes.copyright ?? ""
        let storeXid = matchedSong.attributes.isrc ?? ""
        let subscriptionStoreItemId = audioTraits.contains { trait in
            trait.caseInsensitiveCompare("atmos") == .orderedSame || trait.caseInsensitiveCompare("spatial") == .orderedSame
        } ? storeItemId : 0
        let masteredForItunes = ((matchedSong.attributes.isMasteredForItunes ?? false) || (matchedSong.attributes.isAppleDigitalMaster ?? false)) ? 1 : 0
        let hlsAssetTraits = audioTraits.contains { $0.caseInsensitiveCompare("atmos") == .orderedSame } ? 32 : 0
        let colorAnalysis = matchedSong.attributes.artwork?.colors.map { MediaLibraryBuilder.colorAnalysisJSON(for: $0) } ?? ""

        var artworkData: Data?
        if let artworkURL = matchedSong.attributes.artwork?.artworkURL() {
            artworkData = try? await URLSession.shared.data(from: artworkURL).0
        }

        return ExperimentalAppleMetadataRepair(
            itemPid: candidate.itemPid,
            albumPid: candidate.albumPid,
            artworkToken: candidate.artworkToken,
            relativePath: candidate.relativePath,
            title: title,
            artist: artist,
            album: album,
            year: year,
            trackNumber: matchedSong.attributes.trackNumber ?? 0,
            trackCount: 0,
            discNumber: matchedSong.attributes.discNumber ?? 0,
            discCount: 0,
            durationMs: matchedSong.attributes.durationInMillis ?? 0,
            explicitRating: explicitRating,
            copyright: copyright,
            storeItemId: storeItemId,
            artistId: artistId,
            composerId: composerId,
            genreStoreId: genreStoreId,
            albumStoreId: albumStoreId,
            storefrontId: storefrontId,
            storeXid: storeXid,
            storeFlavor: storeFlavor,
            releaseDate: releaseDate,
            subscriptionStoreItemId: subscriptionStoreItemId,
            masteredForItunes: masteredForItunes,
            hlsAssetTraits: hlsAssetTraits,
            colorAnalysis: colorAnalysis,
            artworkData: artworkData
        )
    }

    private func storefrontIDForCurrentRegion() -> Int64 {
        let region = UserDefaults.standard.string(forKey: "storeRegion")?.lowercased() ?? "us"
        let storefrontMap: [String: Int64] = [
            "us": 143441, "gb": 143444, "ca": 143455, "au": 143460,
            "de": 143443, "fr": 143442, "jp": 143462, "mx": 143468,
            "es": 143454, "it": 143450, "br": 143503, "kr": 143466,
            "cn": 143465, "in": 143467, "ru": 143469, "se": 143456,
            "nl": 143452, "no": 143457, "dk": 143458, "fi": 143447,
            "at": 143445, "ch": 143459, "be": 143446, "ie": 143449,
            "nz": 143461, "sg": 143464, "hk": 143463, "tw": 143470,
            "ar": 143505, "cl": 143483, "co": 143501, "pe": 143507,
            "ve": 143502, "ec": 143509, "cr": 143495, "pa": 143485,
            "do": 143508, "gt": 143504, "hn": 143510, "sv": 143506,
            "py": 143513, "uy": 143514, "bo": 143516, "ni": 143512,
            "pr": 143522, "ph": 143474, "th": 143475, "my": 143473,
            "id": 143476, "vn": 143471, "pk": 143477, "eg": 143516,
            "sa": 143479, "ae": 143481, "il": 143491, "za": 143472,
            "ng": 143561, "ke": 143529, "pt": 143453, "pl": 143478,
            "tr": 143480, "ua": 143492, "ro": 143487, "hu": 143482,
            "cz": 143489, "gr": 143448, "sk": 143496, "bg": 143526,
            "hr": 143494, "lt": 143520, "lv": 143519, "ee": 143518,
            "si": 143499, "lu": 143451, "mt": 143521
        ]
        return storefrontMap[region] ?? 143441
    }

    private func experimentalAlbumArtworkPointerCandidates(db: OpaquePointer?) -> [AlbumArtworkPointerCandidate] {
        let sql = """
        SELECT
            i.album_pid,
            COALESCE(MAX(CASE WHEN at.artwork_source_type = 1 THEN at.artwork_token END), ''),
            GROUP_CONCAT(DISTINCT at.artwork_source_type),
            COALESCE(al.album, '')
        FROM item i
        JOIN artwork_token at
          ON at.entity_pid = i.item_pid
         AND at.entity_type = 0
         AND at.artwork_type = 1
         AND at.artwork_source_type IN (1, 300)
        JOIN artwork aw
          ON aw.artwork_token = at.artwork_token
         AND aw.artwork_source_type = at.artwork_source_type
         AND aw.artwork_variant_type = at.artwork_variant_type
        LEFT JOIN album al ON al.album_pid = i.album_pid
        LEFT JOIN best_artwork_token bat1
          ON bat1.entity_pid = i.album_pid
         AND bat1.entity_type = 1
         AND bat1.artwork_type = 1
         AND bat1.artwork_variant_type = 0
        LEFT JOIN best_artwork_token bat4
          ON bat4.entity_pid = i.album_pid
         AND bat4.entity_type = 4
         AND bat4.artwork_type = 1
         AND bat4.artwork_variant_type = 0
        WHERE i.album_pid != 0
          AND (COALESCE(bat1.available_artwork_token, '') = '' OR COALESCE(bat4.available_artwork_token, '') = '')
        GROUP BY i.album_pid, al.album
        HAVING COALESCE(MAX(CASE WHEN at.artwork_source_type = 1 THEN at.artwork_token END), '') != ''
        """

        var stmt: OpaquePointer?
        var candidates: [AlbumArtworkPointerCandidate] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return candidates
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let albumPid = sqlite3_column_int64(stmt, 0)
            guard albumPid != 0,
                  let tokenPtr = sqlite3_column_text(stmt, 1) else {
                continue
            }

            let token = String(cString: tokenPtr)
            guard !token.isEmpty else { continue }

            let sourceList = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "1"
            let albumName = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "Unknown Album"
            let sourceTypes = sourceList
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

            candidates.append(AlbumArtworkPointerCandidate(
                albumPid: albumPid,
                token: token,
                sourceTypes: sourceTypes.isEmpty ? [1] : sourceTypes,
                albumName: albumName
            ))
        }

        return candidates
    }

    private func applyExperimentalAppleMetadataRepairs(
        db: OpaquePointer?,
        repairs: [ExperimentalAppleMetadataRepair],
        progress: @escaping (String) -> Void
    ) -> Int {
        _ = sqliteExec(db, "BEGIN IMMEDIATE TRANSACTION")

        var repaired = 0
        for (index, repair) in repairs.enumerated() {
            progress("Applying refreshed metadata \(index + 1)/\(repairs.count)...")

            let escapedTitle = repair.title.replacingOccurrences(of: "'", with: "''")
            let escapedArtist = repair.artist.replacingOccurrences(of: "'", with: "''")
            let escapedAlbum = repair.album.replacingOccurrences(of: "'", with: "''")
            let escapedCopyright = repair.copyright.replacingOccurrences(of: "'", with: "''")
            let escapedStoreXid = repair.storeXid.replacingOccurrences(of: "'", with: "''")
            let escapedStoreFlavor = repair.storeFlavor.replacingOccurrences(of: "'", with: "''")
            let escapedColorAnalysis = repair.colorAnalysis.replacingOccurrences(of: "'", with: "''")
            let escapedToken = repair.artworkToken.replacingOccurrences(of: "'", with: "''")
            let escapedRelativePath = repair.relativePath.replacingOccurrences(of: "'", with: "''")

            let ok1 = sqliteExec(db, """
            UPDATE item
            SET disc_number = CASE WHEN \(repair.discNumber) > 0 THEN \(repair.discNumber) ELSE disc_number END,
                track_number = CASE WHEN \(repair.trackNumber) > 0 THEN \(repair.trackNumber) ELSE track_number END
            WHERE item_pid = \(repair.itemPid)
            """)

            let ok2 = sqliteExec(db, """
            UPDATE item_extra
            SET title = '\(escapedTitle)',
                sort_title = '\(escapedTitle)',
                disc_count = CASE WHEN \(repair.discCount) > 0 THEN \(repair.discCount) ELSE disc_count END,
                track_count = CASE WHEN \(repair.trackCount) > 0 THEN \(repair.trackCount) ELSE track_count END,
                total_time_ms = CASE WHEN \(repair.durationMs) > 0 THEN \(repair.durationMs) ELSE total_time_ms END,
                year = CASE WHEN \(repair.year) > 0 THEN \(repair.year) ELSE year END,
                content_rating = \(repair.explicitRating),
                copyright = '\(escapedCopyright)'
            WHERE item_pid = \(repair.itemPid)
            """)

            let ok3 = sqliteExec(db, """
            UPDATE item_artist
            SET item_artist = '\(escapedArtist)',
                sort_item_artist = '\(escapedArtist)',
                store_id = CASE WHEN \(repair.artistId) > 0 THEN \(repair.artistId) ELSE store_id END
            WHERE item_artist_pid = (SELECT item_artist_pid FROM item WHERE item_pid = \(repair.itemPid))
            """)

            let ok4 = sqliteExec(db, """
            UPDATE album_artist
            SET album_artist = '\(escapedArtist)',
                sort_album_artist = '\(escapedArtist)',
                store_id = CASE WHEN \(repair.artistId) > 0 THEN \(repair.artistId) ELSE store_id END
            WHERE album_artist_pid = (SELECT album_artist_pid FROM item WHERE item_pid = \(repair.itemPid))
            """)

            let ok5 = sqliteExec(db, """
            UPDATE album
            SET album = '\(escapedAlbum)',
                sort_album = '\(escapedAlbum)',
                album_year = CASE WHEN \(repair.year) > 0 THEN \(repair.year) ELSE album_year END,
                store_id = CASE WHEN \(repair.albumStoreId) > 0 THEN \(repair.albumStoreId) ELSE store_id END
            WHERE album_pid = \(repair.albumPid)
            """)

            let ok6 = sqliteExec(db, """
            UPDATE item_store
            SET store_xid = '\(escapedStoreXid)',
                store_item_id = \(repair.storeItemId),
                storefront_id = \(repair.storefrontId),
                store_composer_id = CASE WHEN \(repair.composerId) > 0 THEN \(repair.composerId) ELSE store_composer_id END,
                store_genre_id = CASE WHEN \(repair.genreStoreId) > 0 THEN \(repair.genreStoreId) ELSE store_genre_id END,
                store_playlist_id = CASE WHEN \(repair.albumStoreId) > 0 THEN \(repair.albumStoreId) ELSE store_playlist_id END,
                date_released = CASE WHEN \(repair.releaseDate) > 0 THEN \(repair.releaseDate) ELSE date_released END,
                subscription_store_item_id = \(repair.subscriptionStoreItemId),
                is_mastered_for_itunes = \(repair.masteredForItunes),
                store_flavor = '\(escapedStoreFlavor)'
            WHERE item_pid = \(repair.itemPid)
            """)

            let ok7 = sqliteExec(db, """
            INSERT OR REPLACE INTO item_video (item_pid, hls_asset_traits)
            VALUES (\(repair.itemPid), \(repair.hlsAssetTraits))
            """)

            let ok8 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork (
                artwork_token, artwork_source_type, relative_path, artwork_type, interest_data, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 1, '\(escapedRelativePath)', 1, '\(escapedColorAnalysis)', 0
            )
            """)

            let ok9 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork (
                artwork_token, artwork_source_type, relative_path, artwork_type, interest_data, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 300, '\(escapedRelativePath)', 6, '\(escapedColorAnalysis)', 0
            )
            """)

            let ok10 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 1, 1, \(repair.itemPid), 0, 0
            )
            """)

            let ok11 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 1, 1, \(repair.albumPid), 1, 0
            )
            """)

            let ok12 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 1, 1, \(repair.albumPid), 4, 0
            )
            """)

            let ok13 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 1, 1, (SELECT item_artist_pid FROM item WHERE item_pid = \(repair.itemPid)), 2, 0
            )
            """)

            let ok14 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 300, 1, \(repair.itemPid), 0, 0
            )
            """)

            let ok15 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(escapedToken)', 300, 6, \(repair.albumPid), 4, 0
            )
            """)

            let ok16 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(repair.itemPid), 0, 1, '\(escapedToken)', '', 0, 0
            )
            """)

            let ok17 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(repair.albumPid), 1, 1, '\(escapedToken)', '', 0, 0
            )
            """)

            let ok18 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(repair.albumPid), 4, 1, '\(escapedToken)', '', 0, 0
            )
            """)

            let ok19 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(repair.albumPid), 4, 6, '\(escapedToken)', '', 0, 0
            )
            """)

            let ok20 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                (SELECT item_artist_pid FROM item WHERE item_pid = \(repair.itemPid)), 2, 1, '\(escapedToken)', '', 0, 0
            )
            """)

            if ok1 || ok2 || ok3 || ok4 || ok5 || ok6 || ok7 || ok8 || ok9 || ok10 || ok11 || ok12 || ok13 || ok14 || ok15 || ok16 || ok17 || ok18 || ok19 || ok20 {
                repaired += 1
            }
        }

        _ = sqliteExec(db, repaired > 0 ? "COMMIT" : "ROLLBACK")
        return repaired
    }

    private func uploadExperimentalArtworkFiles(
        repairs: [ExperimentalAppleMetadataRepair],
        progress: @escaping (String) -> Void
    ) -> Int {
        let uploads = repairs
            .filter { $0.artworkData != nil && !$0.relativePath.isEmpty }
            .reduce(into: [String: ExperimentalAppleMetadataRepair]()) { partial, repair in
                partial[repair.relativePath] = repair
            }
            .values
            .sorted { $0.relativePath < $1.relativePath }

        guard !uploads.isEmpty else { return 0 }

        var afc: AfcClientHandle?
        connectAfcClient(&afc)
        guard afc != nil else {
            Logger.shared.log("[AlbumArtworkRepair] AFC unavailable for artwork upload")
            return 0
        }
        defer { afc_client_free(afc) }

        var uploadedCount = 0
        for (index, repair) in uploads.enumerated() {
            guard let artworkData = repair.artworkData else { continue }

            progress("Uploading refreshed artwork \(index + 1)/\(uploads.count)...")
            let folderName = (repair.relativePath as NSString).deletingLastPathComponent
            let artworkPath = "/iTunes_Control/iTunes/Artwork/Originals/\(repair.relativePath)"

            _ = afc_make_directory(afc, "/iTunes_Control/iTunes/Artwork/Originals")
            if !folderName.isEmpty && folderName != "." {
                _ = afc_make_directory(afc, "/iTunes_Control/iTunes/Artwork/Originals/\(folderName)")
            }

            if uploadDataToDeviceWithReconnect(artworkData, remotePath: artworkPath, afc: &afc, verify: false) {
                uploadedCount += 1
            }
        }

        return uploadedCount
    }

    private func applyExperimentalAlbumArtworkPointerRepairs(
        db: OpaquePointer?,
        candidates: [AlbumArtworkPointerCandidate],
        progress: @escaping (String) -> Void
    ) -> Int {
        _ = sqliteExec(db, "BEGIN IMMEDIATE TRANSACTION")

        var repaired = 0
        for (index, candidate) in candidates.enumerated() {
            progress("Rebuilding album artwork \(index + 1)/\(candidates.count)...")

            let escapedToken = candidate.token.replacingOccurrences(of: "'", with: "''")
            var changed = false

            for sourceType in Set(candidate.sourceTypes).sorted() {
                let insertedAlbum1 = sqliteExec(db, """
                INSERT OR REPLACE INTO artwork_token (
                    artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
                ) VALUES (
                    '\(escapedToken)', \(sourceType), 1, \(candidate.albumPid), 1, 0
                )
                """)

                let insertedAlbum4 = sqliteExec(db, """
                INSERT OR REPLACE INTO artwork_token (
                    artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
                ) VALUES (
                    '\(escapedToken)', \(sourceType), 1, \(candidate.albumPid), 4, 0
                )
                """)

                changed = changed || insertedAlbum1 || insertedAlbum4
            }

            let updatedBest1 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(candidate.albumPid), 1, 1, '\(escapedToken)', '', 0, 0
            )
            """)

            let updatedBest4 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(candidate.albumPid), 4, 1, '\(escapedToken)', '', 0, 0
            )
            """)

            if changed || updatedBest1 || updatedBest4 {
                repaired += 1
            }
        }

        _ = sqliteExec(db, repaired > 0 ? "COMMIT" : "ROLLBACK")
        return repaired
    }

    private func ios26ArtworkRepairCandidates(db: OpaquePointer?) -> [ArtworkRepairCandidate] {
        let sql = """
        SELECT DISTINCT
            i.item_pid,
            i.album_pid,
            IFNULL(s.store_item_id, 0),
            IFNULL(ie.title, ''),
            IFNULL(ia.item_artist, ''),
            IFNULL(al.album, ''),
            at.artwork_token,
            aw.relative_path
        FROM item i
        LEFT JOIN item_store s ON s.item_pid = i.item_pid
        LEFT JOIN item_extra ie ON ie.item_pid = i.item_pid
        LEFT JOIN item_artist ia ON ia.item_artist_pid = i.item_artist_pid
        LEFT JOIN album al ON al.album_pid = i.album_pid
        JOIN artwork_token at
          ON at.entity_pid = i.item_pid
         AND at.entity_type = 0
         AND at.artwork_type = 1
         AND at.artwork_source_type = 1
        JOIN artwork aw
          ON aw.artwork_token = at.artwork_token
         AND aw.artwork_source_type = at.artwork_source_type
         AND aw.artwork_variant_type = at.artwork_variant_type
        WHERE at.artwork_token != ''
          AND aw.relative_path != ''
        """

        var stmt: OpaquePointer?
        var candidates: [ArtworkRepairCandidate] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return candidates
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let tokenPtr = sqlite3_column_text(stmt, 6),
                  let pathPtr = sqlite3_column_text(stmt, 7) else {
                continue
            }

            let title = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let artist = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let album = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""

            candidates.append(ArtworkRepairCandidate(
                itemPid: sqlite3_column_int64(stmt, 0),
                albumPid: sqlite3_column_int64(stmt, 1),
                storeItemId: sqlite3_column_int64(stmt, 2),
                title: title,
                artist: artist,
                album: album,
                artworkToken: String(cString: tokenPtr),
                relativePath: String(cString: pathPtr)
            ))
        }

        return candidates
    }

    private func applyIOS26ArtworkRepairs(db: OpaquePointer?, repairs: [(ArtworkRepairCandidate, String)]) -> Int {
        _ = sqliteExec(db, "BEGIN IMMEDIATE TRANSACTION")
        var repaired = 0

        for (candidate, colorAnalysis) in repairs {
            let token = candidate.artworkToken.replacingOccurrences(of: "'", with: "''")
            let relativePath = candidate.relativePath.replacingOccurrences(of: "'", with: "''")
            let escapedColorAnalysis = colorAnalysis.replacingOccurrences(of: "'", with: "''")

            let ok1 = sqliteExec(db, """
            UPDATE artwork
            SET interest_data = '\(escapedColorAnalysis)'
            WHERE artwork_token = '\(token)'
              AND artwork_source_type IN (1, 300)
            """)

            let ok2 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork (
                artwork_token, artwork_source_type, relative_path, artwork_type, interest_data, artwork_variant_type
            ) VALUES (
                '\(token)', 300, '\(relativePath)', 6, '\(escapedColorAnalysis)', 0
            )
            """)

            let ok3 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(token)', 300, 1, \(candidate.itemPid), 0, 0
            )
            """)

            let ok4 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(candidate.itemPid), 0, 1, '\(token)', '', 0, 0
            )
            """)

            let ok5 = sqliteExec(db, """
            INSERT OR REPLACE INTO artwork_token (
                artwork_token, artwork_source_type, artwork_type, entity_pid, entity_type, artwork_variant_type
            ) VALUES (
                '\(token)', 300, 6, \(candidate.albumPid), 4, 0
            )
            """)

            let ok6 = sqliteExec(db, """
            INSERT OR REPLACE INTO best_artwork_token (
                entity_pid, entity_type, artwork_type, available_artwork_token, fetchable_artwork_token,
                fetchable_artwork_source_type, artwork_variant_type
            ) VALUES (
                \(candidate.albumPid), 4, 6, '\(token)', '', 0, 0
            )
            """)

            if ok1 && ok2 && ok3 && ok4 && ok5 && ok6 {
                repaired += 1
            }
        }

        _ = sqliteExec(db, "COMMIT")
        return repaired
    }
    
    
    func downloadFileFromDevice(remotePath: String, completion: @escaping (Data?) -> Void) {
        Logger.shared.log("[DeviceManager] downloadFileFromDevice called for: \(remotePath)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?

            for attempt in 1...2 {
                var file: AfcFileHandle?
                self.connectAfcClient(&afc)

                if afc == nil {
                    Logger.shared.log("[DeviceManager] ERROR: AFC client is nil for download")
                    guard attempt < 2, self.ensureActiveTransport(reason: "download \(remotePath)") else {
                        completion(nil)
                        return
                    }
                    continue
                }

                afc_file_open(afc, remotePath, AfcRdOnly, &file)

                guard file != nil else {
                    if attempt < 2, self.reconnectAfcClient(&afc, reason: remotePath) {
                        continue
                    }

                    Logger.shared.log("[DeviceManager] File does not exist or cannot be opened: \(remotePath)")
                    afc_client_free(afc)
                    completion(nil)
                    return
                }

                var dataPtr: UnsafeMutablePointer<UInt8>? = nil
                var length: Int = 0

                let err = afc_file_read_entire(file, &dataPtr, &length)

                if err == nil, let dataPtr = dataPtr, length > 0 {
                    let data = Data(bytes: dataPtr, count: length)
                    Logger.shared.log("[DeviceManager] Downloaded \(length) bytes from \(remotePath)")
                    afc_file_read_data_free(dataPtr, length)
                    afc_file_close(file)
                    afc_client_free(afc)
                    completion(data)
                    return
                }

                afc_file_close(file)
                if attempt < 2, self.reconnectAfcClient(&afc, reason: remotePath) {
                    continue
                }

                Logger.shared.log("[DeviceManager] Failed to read file: \(remotePath)")
                afc_client_free(afc)
                completion(nil)
                return
            }
        }
    }
    
    
    
    func uploadFileToDevice(localURL: URL, remotePath: String, completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] uploadFileToDevice called: \(localURL.lastPathComponent) -> \(remotePath)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            
            self.connectAfcClient(&afc)
            
            guard afc != nil else {
                Logger.shared.log("[DeviceManager] ERROR: AFC client is nil for upload")
                completion(false)
                return
            }
            defer { afc_client_free(afc) }

            completion(self.uploadFileToDevice(localURL: localURL, remotePath: remotePath, afc: afc))
        }
    }

    private func reconnectAfcClient(_ afc: inout AfcClientHandle?, reason: String) -> Bool {
        if let currentAfc = afc {
            afc_client_free(currentAfc)
            afc = nil
        }

        Logger.shared.log("[DeviceManager] AFC transport lost, reconnecting (\(reason))...")

        let semaphore = DispatchSemaphore(value: 0)
        var reconnected = false

        startHeartbeat { success in
            reconnected = success
            semaphore.signal()
        }
        semaphore.wait()

        guard reconnected else {
            Logger.shared.log("[DeviceManager] ERROR: Failed to rebuild transport during AFC reconnect")
            return false
        }

        let connectErr = connectAfcClient(&afc)
        guard connectErr == IdeviceSuccess, afc != nil else {
            Logger.shared.log("[DeviceManager] ERROR: Failed to reconnect AFC client")
            return false
        }

        Logger.shared.log("[DeviceManager] AFC client reconnected successfully")
        return true
    }

    private func ensureActiveTransport(reason: String) -> Bool {
        if heartbeatReady && hasActiveTransport && canStillReachDevice() {
            return true
        }

        Logger.shared.log("[DeviceManager] Transport unavailable, reconnecting before \(reason)...")

        let semaphore = DispatchSemaphore(value: 0)
        var connected = false

        startHeartbeat(forceReconnect: true) { success in
            connected = success
            semaphore.signal()
        }
        semaphore.wait()

        if !connected {
            Logger.shared.log("[DeviceManager] ERROR: Failed to reconnect transport before \(reason)")
        }

        return connected
    }

    private func uploadFileToDeviceWithReconnect(localURL: URL, remotePath: String, afc: inout AfcClientHandle?, verify: Bool = true, maxAttempts: Int = 2) -> Bool {
        for attempt in 1...maxAttempts {
            if uploadFileToDevice(localURL: localURL, remotePath: remotePath, afc: afc, verify: verify) {
                return true
            }

            guard attempt < maxAttempts else { break }

            Logger.shared.log("[DeviceManager] Retrying file upload after AFC reconnect (\(attempt)/\(maxAttempts - 1)): \(remotePath)")
            guard reconnectAfcClient(&afc, reason: remotePath) else { break }
        }

        return false
    }

    private func uploadDataToDeviceWithReconnect(_ data: Data, remotePath: String, afc: inout AfcClientHandle?, verify: Bool = true, maxAttempts: Int = 2) -> Bool {
        for attempt in 1...maxAttempts {
            if uploadDataToDevice(data, remotePath: remotePath, afc: afc, verify: verify) {
                return true
            }

            guard attempt < maxAttempts else { break }

            Logger.shared.log("[DeviceManager] Retrying data upload after AFC reconnect (\(attempt)/\(maxAttempts - 1)): \(remotePath)")
            guard reconnectAfcClient(&afc, reason: remotePath) else { break }
        }

        return false
    }

    private func uploadFileToDevice(localURL: URL, remotePath: String, afc: AfcClientHandle?, verify: Bool = true) -> Bool {
        let needsSecurityScope = localURL.startAccessingSecurityScopedResource()
        defer {
            if needsSecurityScope {
                localURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: localURL) else {
            Logger.shared.log("[DeviceManager] ERROR: Could not read file data")
            return false
        }

        return uploadDataToDevice(data, remotePath: remotePath, afc: afc, verify: verify)
    }

    private func ensureRemoteDirectoryExists(_ remoteDirectory: String, afc: AfcClientHandle?) {
        guard afc != nil else { return }

        let trimmed = remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return }

        let hasLeadingSlash = trimmed.hasPrefix("/")
        let components = trimmed.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        var currentPath = hasLeadingSlash ? "" : "."
        for component in components {
            if currentPath.isEmpty || currentPath == "." {
                currentPath = hasLeadingSlash ? "/\(component)" : component
            } else {
                currentPath += "/\(component)"
            }
            afc_make_directory(afc, currentPath)
        }
    }

    private func uploadDataToDevice(_ data: Data, remotePath: String, afc: AfcClientHandle?, verify: Bool = true) -> Bool {
        var file: AfcFileHandle?

        guard afc != nil else {
            Logger.shared.log("[DeviceManager] ERROR: AFC client is nil for upload")
            return false
        }

        let parentDir = (remotePath as NSString).deletingLastPathComponent
        ensureRemoteDirectoryExists(parentDir, afc: afc)
        afc_remove_path(afc, remotePath)
        afc_file_open(afc, remotePath, AfcWrOnly, &file)

        guard file != nil else {
            Logger.shared.log("[DeviceManager] ERROR: Could not open remote file: \(remotePath)")
            return false
        }

        guard !data.isEmpty else {
            afc_file_close(file)
            Logger.shared.log("[DeviceManager] ERROR: Refusing to upload empty file: \(remotePath)")
            return false
        }

        let writeErr: IdeviceErrorCode = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return afc_file_write(file, base, data.count)
        }

        afc_file_close(file)

        guard writeErr == nil else {
            Logger.shared.log("[DeviceManager] ERROR: Failed to write remote file: \(remotePath)")
            return false
        }

        guard verify else { return true }

        var checkFile: AfcFileHandle?
        let ret = afc_file_open(afc, remotePath, AfcRdOnly, &checkFile)
        if ret == nil {
            if checkFile != nil {
                afc_file_close(checkFile)
            }
            return true
        }

        Logger.shared.log("[DeviceManager] ERROR: Verification failed for \(remotePath)")
        return false
    }
    
    
    
    func listFiles(remotePath: String, completion: @escaping ([String]?) -> Void) {
        Logger.shared.log("[DeviceManager] listFiles called for: \(remotePath)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            var afc: AfcClientHandle?
            for attempt in 1...2 {
                self.connectAfcClient(&afc)
                
                if afc == nil {
                    Logger.shared.log("[DeviceManager] ERROR: AFC client is nil for listFiles")
                    guard attempt < 2, self.ensureActiveTransport(reason: "list files \(remotePath)") else {
                        completion(nil)
                        return
                    }
                    continue
                }
                
                var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
                var count: Int = 0
                
                let err = afc_list_directory(afc, remotePath, &entries, &count)
                
                var files: [String] = []
                
                if err == nil, let list = entries {
                    for i in 0..<count {
                        if let ptr = list[i] {
                            let name = String(cString: ptr)
                            if name != "." && name != ".." {
                                files.append(name)
                            }
                        }
                    }
                    
                    free(entries)
                    afc_client_free(afc)
                    completion(files)
                    return
                }

                if attempt < 2, self.reconnectAfcClient(&afc, reason: remotePath) {
                    continue
                }

                Logger.shared.log("[DeviceManager] Error reading directory or empty: \(remotePath)")
                afc_client_free(afc)
                completion(files)
                return
            }
        }
    }
    
    
    
    func injectSongs(songs: [SongMetadata], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] injectSongs called with \(songs.count) songs")

        DispatchQueue.global(qos: .userInitiated).async {
            var validSongs: [SongMetadata] = []
            let isBatch = songs.count > 1

            for var song in songs {
                if song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let filename = song.localURL.lastPathComponent
                    Logger.shared.log("[DeviceManager] Sanitize: Empty title for '\(filename)', using filename.")
                    song.title = filename
                }

                if song.artist.isEmpty { song.artist = "Unknown Artist" }
                if song.album.isEmpty { song.album = "Unknown Album" }

                if isBatch && song.artist == "Unknown Artist" && song.album == "Unknown Album" {
                    Logger.shared.log("[DeviceManager] Batch Mode: Preserving song with fallback metadata '\(song.title)'")
                }

                if song.artworkData == nil {
                    let semaphore = DispatchSemaphore(value: 0)
                    var extractedArtwork: Data?
                    Task {
                        extractedArtwork = await SongMetadata.extractEmbeddedArtwork(from: song.localURL)
                        semaphore.signal()
                    }
                    semaphore.wait()
                    song.artworkData = extractedArtwork
                }

                validSongs.append(song)
            }

            Logger.shared.log("[DeviceManager] Processing \(validSongs.count) songs (Sanitized).")

            if validSongs.isEmpty {
                Logger.shared.log("[DeviceManager] ⚠️ ABORTING: No songs found.")
                DispatchQueue.main.async { completion(true) }
                return
            }
            if self.killMusicBeforeInjectEnabled {
                progress("Preparing device state...")
                let killed = self.terminateMusicAppIfRunning()
                Logger.shared.log("[SyncLifecycle] Music pre-kill \(killed ? "completed" : "skipped/failed")")
            }
            
            let musicDir = self.resolvePrimaryMusicDirectory()
            
            Logger.shared.log("[DeviceManager] Step 0: Listing existing files in \(musicDir)")
            var onDeviceFiles: Set<String> = []
            let semFiles = DispatchSemaphore(value: 0)
            
            self.listFiles(remotePath: musicDir) { files in
                if let f = files {
                    onDeviceFiles = Set(f)
                }
                semFiles.signal()
            }
            semFiles.wait()
            Logger.shared.log("[DeviceManager] Found \(onDeviceFiles.count) actual files on device")
            
            
            progress("Checking for existing library...")
            Logger.shared.log("[DeviceManager] Step 1: Downloading existing database")
            
            let semaphoreDownload = DispatchSemaphore(value: 0)
            var existingDbData: Data?
            var walData: Data?
            var shmData: Data?
            
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
                existingDbData = data
                semaphoreDownload.signal()
            }
            semaphoreDownload.wait()
            
            
            let semWal = DispatchSemaphore(value: 0)
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
                walData = data
                semWal.signal()
            }
            semWal.wait()
            
            
            let semShm = DispatchSemaphore(value: 0)
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
                shmData = data
                semShm.signal()
            }
            semShm.wait()

            let hasExistingLibrary = self.hasUsableExistingLibrary(dbData: existingDbData, walData: walData, shmData: shmData)
            Logger.shared.log(
                "[DeviceManager] Existing library probe: db=\(existingDbData?.count ?? 0) bytes, wal=\(walData?.count ?? 0) bytes, shm=\(shmData?.count ?? 0) bytes, usable=\(hasExistingLibrary)"
            )
            
            
            progress("Setting up directories...")
            Logger.shared.log("[DeviceManager] Step 2: Setting up directories")
            var afc: AfcClientHandle?
            self.connectAfcClient(&afc)
            
            guard afc != nil else {
                Logger.shared.log("[DeviceManager] ERROR: AFC client is nil")
                DispatchQueue.main.async { completion(false) }
                return
            }
            defer { afc_client_free(afc) }
            
            
            
            
            self.ensureRemoteDirectoryExists("/iTunes_Control", afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/Music", afc: afc)
            self.ensureRemoteDirectoryExists(musicDir, afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes", afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork", afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork/Originals", afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork/Caches", afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/Artwork", afc: afc)
            Logger.shared.log("[DeviceManager] Step 2: Directories created")

            if !hasExistingLibrary {
                Logger.shared.log("[DeviceManager] Fresh-library path: refreshing AFC session before first upload")
                if !self.reconnectAfcClient(&afc, reason: "fresh library bootstrap") {
                    Logger.shared.log("[DeviceManager] ERROR: Failed to refresh AFC session for fresh library upload")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                self.ensureRemoteDirectoryExists(musicDir, afc: afc)
                self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork/Originals", afc: afc)
            }

            var dbURL: URL
            var existingFiles = Set<String>()
            var artworkInfo: [MediaLibraryBuilder.ArtworkInfo] = []
            
            do {
                
                if hasExistingLibrary, let existingData = existingDbData {
                    progress("Merging with existing library...")
                    Logger.shared.log("[DeviceManager] Step 3: Merging with existing database (\(existingData.count) bytes)")
                    
                    let version = self.getDatabaseVersion()
                    let result = try MediaLibraryBuilder.addSongsToExistingDatabase(
                        existingDbData: existingData,
                        walData: walData,
                        shmData: shmData,
                        newSongs: validSongs,
                        existingOnDeviceFiles: onDeviceFiles,
                        version: version
                    )
                    dbURL = result.dbURL
                    existingFiles = result.existingFiles
                    artworkInfo = result.artworkInfo
                    
                    Logger.shared.log("[DeviceManager] Existing files on device: \(existingFiles.count), artwork entries: \(artworkInfo.count)")
                } else {
                    if let existingDbData {
                        Logger.shared.log("[DeviceManager] Existing database is not usable as a merge base (\(existingDbData.count) bytes main DB, wal \(walData?.count ?? 0) bytes), creating fresh")
                    }
                    
                    progress("Creating new library...")
                    Logger.shared.log("[DeviceManager] Step 3: Creating fresh database")
                    let version = self.getDatabaseVersion()
                    let createResult = try MediaLibraryBuilder.createDatabase(songs: validSongs, version: version)
                    dbURL = createResult.dbURL
                    artworkInfo = createResult.artworkInfo
                }
            } catch {
                
                
                Logger.shared.log("[DeviceManager] ⚠️ MERGE FAILED: \(error)")
                Logger.shared.log("[DeviceManager] Aborting to preserve existing library. User should restart their iPhone and try again.")
                progress("Error: Could not merge. Restart iPhone and retry.")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            
            progress("Uploading songs...")
            Logger.shared.log("[DeviceManager] Step 4: Uploading \(validSongs.count) audio files (RP Pairing: \(self.requiresRPPairingTunnel))")

            var uploadedCount = 0
            var skippedCount = 0

            // Separate songs that need uploading from those already on device
            var toUpload: [(index: Int, song: SongMetadata)] = []
            for (index, song) in validSongs.enumerated() {
                if existingFiles.contains(song.remoteFilename) {
                    Logger.shared.log("[DeviceManager] Skipping (already exists): \(song.title)")
                    skippedCount += 1
                } else {
                    toUpload.append((index, song))
                }
            }

            if self.requiresRPPairingTunnel && toUpload.count > 1 {
                // Parallel uploads for iOS 26.4+ (RP Pairing).
                // Each call to connectAfcClient creates an independent channel over the
                // existing rpAdapter/rpHandshake — safe to do from multiple threads.
                let lock = NSLock()
                var uploadFailed = false
                let concurrency = min(toUpload.count, 5)
                let throttle = DispatchSemaphore(value: concurrency)
                let group = DispatchGroup()

                for (_, song) in toUpload {
                    group.enter()
                    throttle.wait()

                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { throttle.signal(); group.leave() }

                        var localAfc: AfcClientHandle?
                        _ = self.connectAfcClient(&localAfc)
                        defer { if let a = localAfc { afc_client_free(a) } }

                        let remotePath = "\(musicDir)/\(song.remoteFilename)"
                        let ok = self.uploadFileToDevice(localURL: song.localURL, remotePath: remotePath, afc: localAfc, verify: false)

                        lock.lock()
                        if ok {
                            uploadedCount += 1
                            let done = uploadedCount
                            let total = toUpload.count
                            DispatchQueue.main.async { progress("Uploading \(done)/\(total)...") }
                        } else {
                            Logger.shared.log("[DeviceManager] ERROR: Parallel upload failed for \(song.title)")
                            uploadFailed = true
                        }
                        lock.unlock()
                    }
                }

                group.wait()

                if uploadFailed {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
            } else {
                // Sequential upload — used for non-RP-Pairing and single-song batches
                for (_, song) in toUpload {
                    progress("Uploading \(uploadedCount + 1)/\(toUpload.count): \(song.title)")
                    let remotePath = "\(musicDir)/\(song.remoteFilename)"
                    guard self.uploadFileToDeviceWithReconnect(localURL: song.localURL, remotePath: remotePath, afc: &afc, verify: false) else {
                        Logger.shared.log("[DeviceManager] ERROR: Failed to upload \(song.title)")
                        DispatchQueue.main.async { completion(false) }
                        return
                    }
                    uploadedCount += 1
                }
            }

            // Artwork uploads — sequential, keyed to artworkInfo index.
            // Pre-ensure the shared artwork directories once before the loop.
            self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork", afc: afc)
            self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork/Originals", afc: afc)

            for (originalIndex, song) in toUpload {
                guard let artworkData = song.artworkData, originalIndex < artworkInfo.count else { continue }
                let info = artworkInfo[originalIndex]
                let artworkRelativePath = info.artworkHash
                let folderName = artworkRelativePath.components(separatedBy: "/").first ?? "00"
                let artworkDir = "/iTunes_Control/iTunes/Artwork/Originals/\(folderName)"
                let artworkPath = "/iTunes_Control/iTunes/Artwork/Originals/\(artworkRelativePath)"

                self.ensureRemoteDirectoryExists(artworkDir, afc: afc)

                if self.uploadDataToDeviceWithReconnect(artworkData, remotePath: artworkPath, afc: &afc, verify: false) {
                    Logger.shared.log("[DeviceManager] Artwork uploaded: \(artworkPath)")
                } else {
                    Logger.shared.log("[DeviceManager] WARNING: Artwork upload failed for: \(song.title)")
                }
            }

            Logger.shared.log("[DeviceManager] Uploaded: \(uploadedCount), Skipped: \(skippedCount)")
            
            
            
            Logger.shared.log("[DeviceManager] Step 4.5: ArtworkDB generation SKIPPED - iOS handles artwork internally")

            
            
            progress("Uploading database...")
            Logger.shared.log("[DeviceManager] Step 5: Uploading database (Atomic Upgrade)")
            
            let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
            let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
            let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
            let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
            let dbUploadSuccess = self.uploadFileToDeviceWithReconnect(localURL: dbURL, remotePath: tempDBPath, afc: &afc)
            
            if !dbUploadSuccess {
                Logger.shared.log("[DeviceManager] ERROR: Failed to upload temp database")
                DispatchQueue.main.async { completion(false) }
                return
            }

            guard let afcHandle = afc, self.replaceRemoteMediaLibrary(
                tempDBPath: tempDBPath,
                finalDBPath: finalDBPath,
                shmPath: shmPath,
                walPath: walPath,
                afc: afcHandle,
                logContext: "[DeviceManager]"
            ) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            Logger.shared.log("[DeviceManager] Database swapped successfully.")

            progress("Finalizing...")
            Logger.shared.log("[DeviceManager] Step 6: Garbage Collection")
            
            let newFilenames = validSongs.map { $0.remoteFilename }
            let snapshotProtectedFiles = self.protectedFilenamesFromAllSnapshots()
            let allValidFiles = existingFiles.union(newFilenames).union(snapshotProtectedFiles)
            
            Logger.shared.log("[DeviceManager] GC Whitelist: \(allValidFiles.count) files (Old: \(existingFiles.count), New: \(newFilenames.count), SnapshotProtected: \(snapshotProtectedFiles.count))")

            self.cleanUpOrphanedFiles(validFilenames: allValidFiles, musicDir: musicDir) { deletedCount in
                if deletedCount > 0 {
                   Logger.shared.log("[DeviceManager] Garbage Collection finished. Deleted \(deletedCount) orphaned files.")
                } else {
                   Logger.shared.log("[DeviceManager] Garbage Collection finished. No orphans found.")
                }
                
                Logger.shared.log("[DeviceManager] Step 7: Sending sync notification")
                self.sendSyncFinishedNotification()
                
                progress("Complete! Restart your iPhone.")
                Logger.shared.log("[DeviceManager] Injection complete!")
                DispatchQueue.main.async { completion(true) }
            }
        }
    }

    
    
    func injectSongsAsPlaylist(songs: [SongMetadata], playlistName: String? = nil, targetPlaylistPid: Int64? = nil, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] injectSongsAsPlaylist called with \(songs.count) songs, playlist: '\(playlistName ?? "Existing")'")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var validSongs: [SongMetadata] = []
            for var song in songs {
                if song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let filename = song.localURL.lastPathComponent
                    song.title = filename
                }
                if song.artist.isEmpty { song.artist = "Unknown Artist" }
                if song.album.isEmpty { song.album = "Unknown Album" }
                if song.artworkData == nil {
                    let semaphore = DispatchSemaphore(value: 0)
                    var extractedArtwork: Data?
                    Task {
                        extractedArtwork = await SongMetadata.extractEmbeddedArtwork(from: song.localURL)
                        semaphore.signal()
                    }
                    semaphore.wait()
                    song.artworkData = extractedArtwork
                }
                validSongs.append(song)
            }

            if validSongs.isEmpty {
                Logger.shared.log("[DeviceManager] ⚠️ ABORTING: No songs for playlist.")
                DispatchQueue.main.async { completion(true) }
                return
            }
        
            guard let self = self else { return }
            let musicDir = self.resolvePrimaryMusicDirectory()
            
            
            Logger.shared.log("[DeviceManager] Step 0: Listing existing files in \(musicDir)")
            var onDeviceFiles: Set<String> = []
            let semFiles = DispatchSemaphore(value: 0)
            
            self.listFiles(remotePath: musicDir) { files in
                if let f = files {
                    onDeviceFiles = Set(f)
                }
                semFiles.signal()
            }
            semFiles.wait()
            Logger.shared.log("[DeviceManager] Found \(onDeviceFiles.count) actual files on device")

            
            progress("Checking for existing library...")
            Logger.shared.log("[DeviceManager] Step 1: Downloading existing database")
            
            let semaphoreDownload = DispatchSemaphore(value: 0)
            var existingDbData: Data?
            var walData: Data?
            var shmData: Data?
            
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
                existingDbData = data
                semaphoreDownload.signal()
            }
            semaphoreDownload.wait()
            
            
            let semWal = DispatchSemaphore(value: 0)
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
                walData = data
                semWal.signal()
            }
            semWal.wait()
            
            let semShm = DispatchSemaphore(value: 0)
            self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
                shmData = data
                semShm.signal()
            }
            semShm.wait()

            let hasExistingLibrary = self.hasUsableExistingLibrary(dbData: existingDbData, walData: walData, shmData: shmData)
            Logger.shared.log(
                "[DeviceManager] Existing playlist library probe: db=\(existingDbData?.count ?? 0) bytes, wal=\(walData?.count ?? 0) bytes, shm=\(shmData?.count ?? 0) bytes, usable=\(hasExistingLibrary)"
            )
            
            
            var afc: AfcClientHandle?
            self.connectAfcClient(&afc)
            if afc != nil {
                
                
                
                self.ensureRemoteDirectoryExists(musicDir, afc: afc)
                self.ensureRemoteDirectoryExists("/iTunes_Control/iTunes/Artwork/Originals", afc: afc)
                afc_client_free(afc)
            }
            
            
            var dbURL: URL
            var existingFiles = Set<String>()
            var artworkInfo: [MediaLibraryBuilder.ArtworkInfo] = []

            
            do {
                if hasExistingLibrary, let existingData = existingDbData {
                    progress("Merging with existing library...")
                    Logger.shared.log("[DeviceManager] Step 3: Merging with existing database (\(existingData.count) bytes)")
                    
                    let version = self.getDatabaseVersion()
                    let result = try MediaLibraryBuilder.addSongsToExistingDatabase(
                        existingDbData: existingData,
                        walData: walData,
                        shmData: shmData,
                        newSongs: validSongs, 
                        playlistName: playlistName,
                        targetPlaylistPid: targetPlaylistPid,
                        existingOnDeviceFiles: onDeviceFiles,
                        version: version
                    )
                    dbURL = result.dbURL
                    existingFiles = result.existingFiles
                    artworkInfo = result.artworkInfo

                } else {
                    if let existingDbData {
                        Logger.shared.log("[DeviceManager] Existing playlist database is not usable as a merge base (\(existingDbData.count) bytes main DB, wal \(walData?.count ?? 0) bytes), creating fresh")
                    }
                    progress("Creating new library with playlist...")
                    Logger.shared.log("[DeviceManager] Step 3: Creating fresh database with playlist")
                    let version = self.getDatabaseVersion()
                    let createResult = try MediaLibraryBuilder.createDatabase(songs: validSongs, version: version, playlistName: playlistName)
                    dbURL = createResult.dbURL
                    artworkInfo = createResult.artworkInfo

                }
            } catch {
                Logger.shared.log("[DeviceManager] ⚠️ PLAYLIST MERGE FAILED: \(error)")
                Logger.shared.log("[DeviceManager] Aborting to preserve existing library. User should restart their iPhone and try again.")
                progress("Error: Could not merge. Restart iPhone and retry.")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            
            progress("Uploading songs...")
            
            var uploadedCount = 0
            
            for (index, song) in validSongs.enumerated() {
                
                if existingFiles.contains(song.remoteFilename) {
                    continue
                }
                
                progress("Uploading \(index + 1)/\(validSongs.count): \(song.title)")
                
                let semaphore = DispatchSemaphore(value: 0)
                var uploadSuccess = false
                let remotePath = "\(musicDir)/\(song.remoteFilename)"
                
                self.uploadFileToDevice(localURL: song.localURL, remotePath: remotePath) { success in
                    uploadSuccess = success
                    semaphore.signal()
                }
                semaphore.wait()
                
                if !uploadSuccess {
                    Logger.shared.log("[DeviceManager] ERROR: Failed to upload \(song.title)")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                uploadedCount += 1
                
                

            }
            
            

            
            
            
            var artworkIndex = 0
            
            for song in validSongs {
                 if existingFiles.contains(song.remoteFilename) { continue }
                 
                 
                 if song.artworkData != nil {
                     if artworkIndex < artworkInfo.count {
                         let info = artworkInfo[artworkIndex]
                         let artworkData = song.artworkData!
                         
                         let artworkRelativePath = info.artworkHash
                         let pathComponents = artworkRelativePath.components(separatedBy: "/")
                         let fileName = pathComponents.last ?? "unknown"
                         let artworkPath = "/iTunes_Control/iTunes/Artwork/Originals/\(artworkRelativePath)"
                         
                         let tempArtwork = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                         try? artworkData.write(to: tempArtwork)
                         
                         let semArt = DispatchSemaphore(value: 0)
                         self.uploadFileToDevice(localURL: tempArtwork, remotePath: artworkPath) { _ in semArt.signal() }
                         semArt.wait()
                         try? FileManager.default.removeItem(at: tempArtwork)
                         
                         artworkIndex += 1
                     }
                 }
            }

            
            progress("Uploading database...")
            Logger.shared.log("[DeviceManager] Step 5: Uploading database (Atomic Upgrade)")
            
            let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
            let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
            let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
            let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
            
            
            let semUploadDB = DispatchSemaphore(value: 0)
            var dbUploadSuccess = false
            self.uploadFileToDevice(localURL: dbURL, remotePath: tempDBPath) { success in
                dbUploadSuccess = success
                semUploadDB.signal()
            }
            semUploadDB.wait()
            
            if !dbUploadSuccess {
                Logger.shared.log("[DeviceManager] ERROR: Failed to upload temp database")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            
            var afcSwap: AfcClientHandle?
            self.connectAfcClient(&afcSwap)
            
            guard afcSwap != nil else {
                Logger.shared.log("[DeviceManager] ERROR: Failed to connect AFC for atomic swap")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            
            guard let afcSwapHandle = afcSwap, self.replaceRemoteMediaLibrary(
                tempDBPath: tempDBPath,
                finalDBPath: finalDBPath,
                shmPath: shmPath,
                walPath: walPath,
                afc: afcSwapHandle,
                logContext: "[DeviceManager]"
            ) else {
                afc_client_free(afcSwap)
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            Logger.shared.log("[DeviceManager] Database swapped successfully.")
            afc_client_free(afcSwap)
            
            if !dbUploadSuccess {
                Logger.shared.log("[DeviceManager] ERROR: Failed to upload database")
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            
            progress("Finalizing...")
            self.sendSyncFinishedNotification()
            
            progress("Playlist '\(playlistName ?? "Unknown")' updated!")
            Logger.shared.log("[DeviceManager] Playlist injection complete!")
            DispatchQueue.main.async { completion(true) }
        }
    }
    
    func fetchPlaylists(completion: @escaping ([(name: String, pid: Int64)]) -> Void) {
        let dbPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.heartbeatReady else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            var success = false
            var dbData: Data?
            let sem = DispatchSemaphore(value: 0)
            
            self.downloadFileFromDevice(remotePath: dbPath) { data in
                if let data = data {
                    dbData = data
                    success = true
                }
                sem.signal()
            }
            sem.wait()
            
            if !success {
                Logger.shared.log("[DeviceManager] Failed to download DB for playlist fetch")
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            
            let tempDB = FileManager.default.temporaryDirectory.appendingPathComponent("PlaylistFetch.sqlitedb")
            do {
                try dbData?.write(to: tempDB)
            } catch {
                 DispatchQueue.main.async { completion([]) }
                 return
            }
            
            let playlists = MediaLibraryBuilder.extractPlaylists(fromDbPath: tempDB.path)
            try? FileManager.default.removeItem(at: tempDB)
            
            DispatchQueue.main.async { completion(playlists) }
        }
    }
    
    
    
    func injectRingtones(ringtones: [SongMetadata], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) {
        Logger.shared.log("[DeviceManager] injectRingtones called with \(ringtones.count) ringtones")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let dbVersion = self.getDatabaseVersion()
            let requiresRingtoneDBEntries = dbVersion.major <= 18
            let primaryRoot = "/iTunes_Control/Ringtones"
            let legacyRoot = "/iTunes_Control/Ringtons"
            var resolvedRoot = primaryRoot
            
            
            // ── Step 1: Load existing Ringtones.plist (merge, don't overwrite) ──
            progress("Preparing ringtones...")
            Logger.shared.log("[DeviceManager] Downloading existing Ringtones.plist")

            var rootDict: [String: Any] = [:]
            var ringtonesDict: [String: Any] = [:]

            let plistSem = DispatchSemaphore(value: 0)
            self.downloadFileFromDevice(remotePath: "\(primaryRoot)/Ringtones.plist") { data in
                if let data = data {
                    if let dict = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] {
                        rootDict = dict
                        ringtonesDict = (dict["Ringtones"] as? [String: Any]) ?? [:]
                        resolvedRoot = primaryRoot
                        Logger.shared.log("[DeviceManager] Loaded existing plist with \(ringtonesDict.count) entries")
                    }
                } else {
                    let legacySem = DispatchSemaphore(value: 0)
                    self.downloadFileFromDevice(remotePath: "\(legacyRoot)/Ringtones.plist") { legacyData in
                        if let legacyData = legacyData,
                           let dict = try? PropertyListSerialization.propertyList(from: legacyData, options: .mutableContainersAndLeaves, format: nil) as? [String: Any] {
                            rootDict = dict
                            ringtonesDict = (dict["Ringtones"] as? [String: Any]) ?? [:]
                            resolvedRoot = legacyRoot
                            Logger.shared.log("[DeviceManager] Loaded existing legacy plist with \(ringtonesDict.count) entries")
                        }
                        legacySem.signal()
                    }
                    legacySem.wait()
                }
                plistSem.signal()
            }
            plistSem.wait()

            // ── Step 2: Ensure ringtone directories exist ──────────────
            var afcDir: AfcClientHandle?
            self.connectAfcClient(&afcDir)
            if afcDir != nil {
                afc_make_directory(afcDir, primaryRoot)
                afc_make_directory(afcDir, "\(primaryRoot)/Sync")
                afc_make_directory(afcDir, legacyRoot)
                afc_make_directory(afcDir, "\(legacyRoot)/Sync")
                afc_client_free(afcDir)
            }

            // ── Step 3: Upload each .m4r and build the plist entries ─────────
            progress("Uploading ringtones...")
            var uploadedRingtones: [SongMetadata] = []

            for ringtone in ringtones {
                let remotePath = "\(resolvedRoot)/\(ringtone.remoteFilename)"
                let mirrorPath = "\(resolvedRoot == primaryRoot ? legacyRoot : primaryRoot)/\(ringtone.remoteFilename)"

                let uploadSem = DispatchSemaphore(value: 0)
                var uploadOK = false
                self.uploadFileToDevice(localURL: ringtone.localURL, remotePath: remotePath) { s in
                    uploadOK = s
                    uploadSem.signal()
                }
                uploadSem.wait()
                
                let mirrorSem = DispatchSemaphore(value: 0)
                self.uploadFileToDevice(localURL: ringtone.localURL, remotePath: mirrorPath) { _ in
                    mirrorSem.signal()
                }
                mirrorSem.wait()

                if uploadOK {
                    Logger.shared.log("[DeviceManager] Uploaded: \(ringtone.remoteFilename)")
                    uploadedRingtones.append(ringtone)
                } else {
                    Logger.shared.log("[DeviceManager] WARNING: Failed to upload \(ringtone.remoteFilename)")
                    continue
                }

                let pid  = SongMetadata.generatePersistentId()
                let guid = String(format: "%016llX", SongMetadata.generatePersistentId())

                let entry: [String: Any] = [
                    "Name":              ringtone.title,
                    "Total Time":        ringtone.durationMs,   // real duration ms
                    "PID":               pid,
                    "Protected Content": false,
                    "GUID":              guid
                ]
                ringtonesDict[ringtone.remoteFilename] = entry
                Logger.shared.log("[DeviceManager] Plist entry: \(ringtone.remoteFilename) PID=\(pid) GUID=\(guid)")
            }

            // ── Step 4: Upload merged Ringtones.plist (binary format) ────────
            rootDict["Ringtones"] = ringtonesDict

            do {
                let tempDir  = FileManager.default.temporaryDirectory
                let plistData = try PropertyListSerialization.data(fromPropertyList: rootDict, format: .binary, options: 0)
                let tempPlist = tempDir.appendingPathComponent("Ringtones.plist")
                try plistData.write(to: tempPlist)

                let plistSem2 = DispatchSemaphore(value: 0)
                self.uploadFileToDevice(localURL: tempPlist, remotePath: "\(resolvedRoot)/Ringtones.plist") { _ in
                    plistSem2.signal()
                }
                plistSem2.wait()
                
                let plistSemMirror = DispatchSemaphore(value: 0)
                let mirrorPlistRoot = (resolvedRoot == primaryRoot) ? legacyRoot : primaryRoot
                self.uploadFileToDevice(localURL: tempPlist, remotePath: "\(mirrorPlistRoot)/Ringtones.plist") { _ in
                    plistSemMirror.signal()
                }
                plistSemMirror.wait()
                Logger.shared.log("[DeviceManager] Ringtones.plist uploaded (\(ringtonesDict.count) total entries)")
            } catch {
                Logger.shared.log("[DeviceManager] Failed to upload Ringtones.plist: \(error)")
            }
            
            // ── Step 5: Write SyncAnchor marker files (seen in iOS 17/18 exports) ──
            do {
                let anchor: [String: Any] = ["syncAnchor": "1"]
                let anchorData = try PropertyListSerialization.data(fromPropertyList: anchor, format: .binary, options: 0)
                let anchorURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyncAnchor.plist")
                try anchorData.write(to: anchorURL)
                
                let anchorSem1 = DispatchSemaphore(value: 0)
                self.uploadFileToDevice(localURL: anchorURL, remotePath: "\(resolvedRoot)/SyncAnchor.plist") { _ in
                    anchorSem1.signal()
                }
                anchorSem1.wait()
                
                let anchorSem2 = DispatchSemaphore(value: 0)
                let mirrorAnchorRoot = (resolvedRoot == primaryRoot) ? legacyRoot : primaryRoot
                self.uploadFileToDevice(localURL: anchorURL, remotePath: "\(mirrorAnchorRoot)/SyncAnchor.plist") { _ in
                    anchorSem2.signal()
                }
                anchorSem2.wait()
                Logger.shared.log("[Ringtone-DB] SyncAnchor.plist uploaded")
            } catch {
                Logger.shared.log("[Ringtone-DB] Failed to upload SyncAnchor.plist: \(error)")
            }
            
            // ── Step 6: On iOS 18 and lower, also insert ringtone rows into MediaLibrary DB ──
            if requiresRingtoneDBEntries && !uploadedRingtones.isEmpty {
                progress("Updating ringtone database...")
                Logger.shared.log("[Ringtone-DB] iOS \(dbVersion.major) detected: inserting DB rows for \(uploadedRingtones.count) ringtone(s)")
                
                var dbData: Data?
                var walData: Data?
                var shmData: Data?
                
                let dbSem = DispatchSemaphore(value: 0)
                self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb") { data in
                    dbData = data
                    dbSem.signal()
                }
                dbSem.wait()
                
                guard let baseDbData = dbData else {
                    Logger.shared.log("[Ringtone-DB] Failed to download MediaLibrary.sqlitedb, skipping DB insertion")
                    progress("Done!")
                    self.postRingtoneRefreshNotifications()
                    DispatchQueue.main.async { completion(true) }
                    return
                }
                
                let walSem = DispatchSemaphore(value: 0)
                self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal") { data in
                    walData = data
                    walSem.signal()
                }
                walSem.wait()
                
                let shmSem = DispatchSemaphore(value: 0)
                self.downloadFileFromDevice(remotePath: "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm") { data in
                    shmData = data
                    shmSem.signal()
                }
                shmSem.wait()
                
                do {
                    let updatedDbURL = try MediaLibraryBuilder.addRingtonesToExistingDatabase(
                        existingDbData: baseDbData,
                        walData: walData,
                        shmData: shmData,
                        ringtones: uploadedRingtones
                    )
                    
                    let tempDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb.temp"
                    let finalDBPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
                    let shmPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-shm"
                    let walPath = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb-wal"
                    
                    let uploadSem = DispatchSemaphore(value: 0)
                    var uploadOK = false
                    self.uploadFileToDevice(localURL: updatedDbURL, remotePath: tempDBPath) { ok in
                        uploadOK = ok
                        uploadSem.signal()
                    }
                    uploadSem.wait()
                    
                    if uploadOK {
                        var afcSwap: AfcClientHandle?
                        self.connectAfcClient(&afcSwap)
                        if let afcSwap {
                            if self.replaceRemoteMediaLibrary(
                                tempDBPath: tempDBPath,
                                finalDBPath: finalDBPath,
                                shmPath: shmPath,
                                walPath: walPath,
                                afc: afcSwap,
                                logContext: "[Ringtone-DB]"
                            ) {
                                Logger.shared.log("[Ringtone-DB] Database swapped successfully with ringtone entries")
                            } else {
                                Logger.shared.log("[Ringtone-DB] Failed to swap database after ringtone insert")
                            }
                            afc_client_free(afcSwap)
                        } else {
                            Logger.shared.log("[Ringtone-DB] Could not open AFC for database swap")
                        }
                    } else {
                        Logger.shared.log("[Ringtone-DB] Failed to upload updated ringtone database")
                    }
                } catch {
                    Logger.shared.log("[Ringtone-DB] Failed to build/update ringtone database: \(error)")
                }
            } else {
                Logger.shared.log("[Ringtone-DB] DB insertion not required for iOS \(dbVersion.major)")
            }

            progress("Done!")
            self.postRingtoneRefreshNotifications()
            DispatchQueue.main.async { completion(true) }
        }
    }
}


extension URL {
    static var documentsDirectory: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}
