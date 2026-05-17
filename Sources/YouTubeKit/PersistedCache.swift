//
//  PersistedCache.swift
//  YouTubeKit
//
//  Stores the base.js player code, jsURL, signature timestamp, and YtCfg
//  to disk so subsequent app launches can skip the watchHTML + base.js fetch
//  pipeline on the warm path. On signature failure the cache is invalidated.
//

import Foundation
import os.log

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
enum PersistedCache {

    private static let log = OSLog(subsystem: "YouTubeKit", category: "PersistedCache")
    private static let fileName = "youtubekit-cache.v1.json"

    struct Snapshot: Codable {
        var jsURL: URL
        var js: String
        var signatureTimestamp: Int?
        var ytcfg: Extraction.YtCfg
        var savedAt: Date
    }

    private static var fileURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return base.appendingPathComponent(fileName)
    }

    static func load() -> Snapshot? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            os_log("PersistedCache load failed, removing: %{public}@", log: log, type: .info, "\(error)")
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    static func save(_ snapshot: Snapshot) {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            os_log("PersistedCache save failed: %{public}@", log: log, type: .info, "\(error)")
        }
    }

    static func invalidate() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
