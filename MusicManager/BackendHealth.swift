import Foundation
import Combine

struct BackendHealthRecord: Codable, Identifiable {
    var id: String { label }
    let label: String
    var lastOutcome: String
    var lastUpdatedAt: Date
    var successCount: Int
    var failureCount: Int
    var lastError: String?
}

@MainActor
final class BackendHealthStore: ObservableObject {
    static let shared = BackendHealthStore()

    @Published private(set) var records: [BackendHealthRecord] = []
    @Published private(set) var lastUsedLabel: String?
    @Published private(set) var isRefreshing = false

    private let recordsKey = "backendHealth.records.v1"
    private let lastUsedKey = "backendHealth.lastUsed.v1"
    private let lastProbeKey = "backendHealth.lastProbe.v1"
    private var lastProbeAt: Date?

    private init() {
        load()
    }

    func recordSuccess(label: String) {
        mutateRecord(label: label, success: true, error: nil)
        lastUsedLabel = label
        persist()
    }

    func recordFailure(label: String, error: String) {
        mutateRecord(label: label, success: false, error: error)
        persist()
    }

    func reportItems() -> [BackendHealthRecord] {
        let knownLabels = Self.knownBackendLabels
        var byLabel = Dictionary(uniqueKeysWithValues: records.map { ($0.label, $0) })

        for label in knownLabels where byLabel[label] == nil {
            byLabel[label] = BackendHealthRecord(
                label: label,
                lastOutcome: "No attempts yet",
                lastUpdatedAt: .distantPast,
                successCount: 0,
                failureCount: 0,
                lastError: nil
            )
        }

        return byLabel.values.sorted { lhs, rhs in
            if lhs.lastUpdatedAt == rhs.lastUpdatedAt {
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            return lhs.lastUpdatedAt > rhs.lastUpdatedAt
        }
    }

    func refreshHealth(for preference: DownloaderServerPreference, force: Bool = false) {
        if isRefreshing { return }
        if !force, let lastProbeAt, Date().timeIntervalSince(lastProbeAt) < 180 {
            return
        }

        let labels = labelsToProbe(for: preference)
        guard !labels.isEmpty else { return }

        isRefreshing = true
        Task {
            await withTaskGroup(of: ProbeResult?.self) { group in
                for label in labels {
                    group.addTask {
                        await Self.probe(label: label)
                    }
                }

                for await result in group {
                    guard let result else { continue }
                    if result.success {
                        self.recordSuccess(label: result.label)
                    } else {
                        self.recordFailure(label: result.label, error: result.errorMessage ?? "Probe failed")
                    }
                }
            }

            self.lastProbeAt = Date()
            self.persist()
            self.isRefreshing = false
        }
    }

    private func mutateRecord(label: String, success: Bool, error: String?) {
        if let index = records.firstIndex(where: { $0.label == label }) {
            records[index].lastOutcome = success ? "Healthy" : "Failing"
            records[index].lastUpdatedAt = Date()
            if success {
                records[index].successCount += 1
                records[index].lastError = nil
            } else {
                records[index].failureCount += 1
                records[index].lastError = error
            }
            return
        }

        records.append(
            BackendHealthRecord(
                label: label,
                lastOutcome: success ? "Healthy" : "Failing",
                lastUpdatedAt: Date(),
                successCount: success ? 1 : 0,
                failureCount: success ? 0 : 1,
                lastError: success ? nil : error
            )
        )
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([BackendHealthRecord].self, from: data) {
            records = decoded
        }
        lastUsedLabel = UserDefaults.standard.string(forKey: lastUsedKey)
        lastProbeAt = UserDefaults.standard.object(forKey: lastProbeKey) as? Date
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: recordsKey)
        }
        UserDefaults.standard.set(lastUsedLabel, forKey: lastUsedKey)
        UserDefaults.standard.set(lastProbeAt, forKey: lastProbeKey)
    }

    private static let knownBackendLabels: [String] = [
        "ByeTunes API",
        "ByeTunes API (MP3 Fallback)",
        "Yoinkify",
        "Qobuz API (Zarz)",
        "Apple Music API (app2)",
        "Apple Music API (app)",
        "Deezer API (Zarz)",
        "Tidal API (tid2)",
        "Tidal API (tid)",
        "Pandora API (Zarz)",
        "Amazon Music API (Zarz)",
        "SoundCloud API (Cobalt)",
        "YouTube API (Cobalt)"
    ]

    private struct ProbeResult {
        let label: String
        let success: Bool
        let errorMessage: String?
    }

    private struct ProbeDefinition {
        let url: URL
        let reachableStatusCodes: ClosedRange<Int>
        let additionalReachableStatusCodes: Set<Int>
    }

    private func labelsToProbe(for preference: DownloaderServerPreference) -> [String] {
        switch preference {
        case .auto:
            return ["ByeTunes API", "Deezer API (Zarz)"]
        case .byeTunesAPI:
            return ["ByeTunes API"]
        case .yoinkify:
            return ["Yoinkify"]
        case .qobuz:
            return ["Qobuz API (Zarz)"]
        case .appleMusicAPI:
            return ["Apple Music API (app2)", "Apple Music API (app)"]
        case .deezerAPI:
            return ["Deezer API (Zarz)"]
        case .tidalAPI:
            return ["Tidal API (tid2)", "Tidal API (tid)"]
        case .pandoraAPI:
            return ["Pandora API (Zarz)"]
        case .amazonAPI:
            return ["Amazon Music API (Zarz)"]
        case .soundCloudAPI:
            return ["SoundCloud API (Cobalt)"]
        case .youtubeAPI:
            return ["YouTube API (Cobalt)"]
        case .hifiOne, .hifiTwo:
            return []
        }
    }

    private static func probe(label: String) async -> ProbeResult? {
        guard let definition = probeDefinition(for: label) else { return nil }

        do {
            var request = URLRequest(url: definition.url)
            request.httpMethod = "GET"
            request.timeoutInterval = 6
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(label: label, success: false, errorMessage: "No HTTP response")
            }

            if definition.reachableStatusCodes.contains(http.statusCode) ||
                definition.additionalReachableStatusCodes.contains(http.statusCode) {
                return ProbeResult(label: label, success: true, errorMessage: nil)
            }

            return ProbeResult(label: label, success: false, errorMessage: "HTTP \(http.statusCode)")
        } catch {
            return ProbeResult(label: label, success: false, errorMessage: error.localizedDescription)
        }
    }

    private static func probeDefinition(for label: String) -> ProbeDefinition? {
        switch label {
        case "ByeTunes API", "ByeTunes API (MP3 Fallback)":
            guard let url = URL(string: Config.byeTunesApiUrl) else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [429])
        case "Yoinkify":
            guard let url = URL(string: "https://yoinkify.com") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [429])
        case "Qobuz API (Zarz)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/qbz") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Apple Music API (app2)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/app2") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Apple Music API (app)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/app/download") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Deezer API (Zarz)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/dzr") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Tidal API (tid2)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/tid2") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Tidal API (tid)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/tid") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Pandora API (Zarz)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/pan") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "Amazon Music API (Zarz)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/amazeamazeamaze/media") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "SoundCloud API (Cobalt)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/cobalt") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        case "YouTube API (Cobalt)":
            guard let url = URL(string: "https://api.zarz.moe/v1/dl/cobalt") else { return nil }
            return ProbeDefinition(url: url, reachableStatusCodes: 200...399, additionalReachableStatusCodes: [400, 401, 403, 404, 405, 422, 429])
        default:
            return nil
        }
    }
}
