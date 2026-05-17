//
//  YouTube.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.09.21.
//

import Foundation
@preconcurrency import os.log

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
public class YouTube {
    
    private var _js: String?
    private var _jsURL: URL?
    
#if swift(>=5.10)
    nonisolated(unsafe) private static var __js: String? // caches js between calls
    nonisolated(unsafe) private static var __jsURL: URL?
    nonisolated(unsafe) private static var __ytcfg: Extraction.YtCfg? // cached cross-instance
    nonisolated(unsafe) private static var __signatureTimestamp: Int?
    nonisolated(unsafe) private static var __diskLoaded = false
#else
    private static var __js: String? // caches js between calls
    private static var __jsURL: URL?
    private static var __ytcfg: Extraction.YtCfg?
    private static var __signatureTimestamp: Int?
    private static var __diskLoaded = false
#endif

    /// Global toggle. When true, YouTubeKit persists the player JS + ytcfg to disk
    /// after the first extraction and skips re-fetching them on later launches.
    /// On signature failure the persisted cache is invalidated and the slow path retries.
    public static var useDiskCache: Bool = true

    /// Per-instance flag. When true, skips the watchHTML fetch entirely on the warm path
    /// (when `__js`, `__jsURL`, `__ytcfg`, `__signatureTimestamp` are all populated).
    /// Set this on YouTube() instances when you already know the video is playable —
    /// e.g. coming from a video card the user just clicked.
    public var skipAvailabilityCheck: Bool = false

    private static func loadDiskCacheIfNeeded() {
        guard useDiskCache, !__diskLoaded else { return }
        __diskLoaded = true
        guard let snap = PersistedCache.load() else { return }
        __js = snap.js
        __jsURL = snap.jsURL
        __ytcfg = snap.ytcfg
        __signatureTimestamp = snap.signatureTimestamp
    }

    private static func saveDiskCache() {
        guard useDiskCache,
              let js = __js, let jsURL = __jsURL, let ytcfg = __ytcfg
        else { return }
        PersistedCache.save(.init(
            jsURL: jsURL, js: js,
            signatureTimestamp: __signatureTimestamp,
            ytcfg: ytcfg, savedAt: Date()
        ))
    }

    private static func invalidateAllCaches() {
        __js = nil; __jsURL = nil; __ytcfg = nil; __signatureTimestamp = nil
        PersistedCache.invalidate()
    }
    
    private var _videoInfos: [InnerTube.VideoInfo]?
    
    private var _watchHTML: String?
    private var _embedHTML: String?
    private var playerConfigArgs: [String: Any]?
    private var _ageRestricted: Bool?
    private var _signatureTimestamp: Int?
    private var _ytcfg: Extraction.YtCfg?
    
    private var _fmtStreams: [Stream]?
    
    private var initialData: Data?

    /// Represents a property that provides metadata for a YouTube video.
    ///
    /// This property allows you to retrieve metadata for a YouTube video asynchronously.
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var metadata: YouTubeMetadata? {
        get async throws {
            return .metadata(from: try await videoDetails)
        }
    }

    public let videoID: String
    
    var watchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)")!
    }
    
    private var extendedWatchURL: URL {
        URL(string: "https://youtube.com/watch?v=\(videoID)&bpctr=9999999999&has_verified=1")!
    }
    
    var embedURL: URL {
        URL(string: "https://www.youtube.com/embed/\(videoID)")!
    }
    
    // stream monostate TODO
    
    private var author: String?
    private var title: String?
    private var publishDate: String?
    
    let useOAuth: Bool
    let allowOAuthCache: Bool
    
    let methods: [ExtractionMethod]

    /// Optional filter applied to raw stream formats before signature decryption.
    /// Returning `true` keeps the format. Filtering early skips JavaScriptCore
    /// signing work for streams you don't care about, which is the dominant
    /// per-video cost. Set this before reading `streams`.
    public var itagFilter: (@Sendable (Int) -> Bool)?

    /// Optional check used during sequential InnerTube extraction. Receives
    /// the itag set of each client's response; return `true` to stop trying
    /// further clients. When unset, the first successful client wins.
    /// Use to early-out as soon as a client returns the format you need
    /// (e.g. `{ $0.contains(137) }` for 1080p AVC1).
    public var responseSatisfied: (@Sendable ([Int]) -> Bool)?

    private let log = OSLog(YouTube.self)
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public init(videoID: String, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        self.videoID = videoID
        self.useOAuth = useOAuth
        self.allowOAuthCache = allowOAuthCache
        // TODO: install proxies if needed
        
        if methods.isEmpty {
#if canImport(JavaScriptCore)
            self.methods = [.local]
#else
            self.methods = [.remote]
#endif
        } else {
            self.methods = methods.removeDuplicates()
        }
    }
    
    /// - parameter methods: Methods used to extract streams from the video - ordered by priority (Default: `local` on iOS, macOS, tvOS, visionOS; `remote` on watchOS)
    public convenience init(url: URL, proxies: [String: URL] = [:], useOAuth: Bool = false, allowOAuthCache: Bool = false, methods: [ExtractionMethod] = .default) {
        let videoID = Extraction.extractVideoID(from: url.absoluteString) ?? ""
        self.init(videoID: videoID, proxies: proxies, useOAuth: useOAuth, allowOAuthCache: allowOAuthCache, methods: methods)
    }
    
    
    private var watchHTML: String {
        get async throws {
            if let cached = _watchHTML {
                return cached
            }
            var request = URLRequest(url: extendedWatchURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _watchHTML = String(data: data, encoding: .utf8) ?? ""
            return _watchHTML!
        }
    }
    
    private var embedHTML: String {
        get async throws {
            if let cached = _embedHTML {
                return cached
            }
            var request = URLRequest(url: embedURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en", forHTTPHeaderField: "accept-language")
            request.httpShouldHandleCookies = false
            let (data, _) = try await URLSession.shared.data(for: request)
            _embedHTML = String(data: data, encoding: .utf8) ?? ""
            return _embedHTML!
        }
    }
    
    
    /// check whether the video is available
    public func checkAvailability() async throws {
        let (status, messages) = try Extraction.playabilityStatus(watchHTML: await watchHTML)

        for reason in messages {
            switch status {
            case .unplayable:
                if reason?.starts(with: "Join this channel to get access to members-only content") ?? false { // TODO: original compared to tuple
                    throw YouTubeKitError.membersOnly
                }
            case .loginRequired:
                if reason.map({ $0.starts(with: "This is a private video") || $0.starts(with: "This video is private") }) ?? false { // TODO: original: reason == ["This is a private video. ", "Please sign in to verify that you may see it."] {
                    throw YouTubeKitError.videoPrivate
                }
            case .error:
                throw YouTubeKitError.videoUnavailable
            case .liveStream:
                let streamingData = try await videoInfos.map { $0.streamingData }
                if streamingData.allSatisfy({ $0?.hlsManifestUrl == nil }) {
                    throw YouTubeKitError.liveStreamError
                }
                continue
            case .ok, .none:
                continue
            }
        }
    }
    
    public var ageRestricted: Bool {
        get async throws {
            if let cached = _ageRestricted {
                return cached
            }
            
            _ageRestricted = try await Extraction.isAgeRestricted(watchHTML: watchHTML)
            return _ageRestricted!
        }
    }
    
    var jsURL: URL {
        get async throws {
            if let cached = _jsURL {
                return cached
            }
            
            if try await ageRestricted {
                _jsURL = try await URL(string: Extraction.jsURL(html: embedHTML))!
            } else {
                _jsURL = try await URL(string: Extraction.jsURL(html: watchHTML))!
            }
            return _jsURL!
        }
    }
    
    var js: String {
        get async throws {
            if let cached = _js {
                return cached
            }

            YouTube.loadDiskCacheIfNeeded()

            // Fast path: trust persisted js without re-fetching watchHTML.
            if skipAvailabilityCheck, let staticJS = YouTube.__js {
                _js = staticJS
                return staticJS
            }

            let jsURL = try await jsURL

            if YouTube.__jsURL != jsURL {
                let (data, _) = try await URLSession.shared.data(from: jsURL)
                _js = String(data: data, encoding: .utf8) ?? ""
                YouTube.__js = _js
                YouTube.__jsURL = jsURL
            } else {
                _js = YouTube.__js
            }
            return _js!
        }
    }

    var signatureTimestamp: Int? {
        get async throws {
            if let cached = _signatureTimestamp {
                return cached
            }

            YouTube.loadDiskCacheIfNeeded()
            if skipAvailabilityCheck, let cached = YouTube.__signatureTimestamp {
                _signatureTimestamp = cached
                return cached
            }

            _signatureTimestamp = try await Extraction.extractSignatureTimestamp(fromJS: js)
            YouTube.__signatureTimestamp = _signatureTimestamp
            return _signatureTimestamp
        }
    }

    var ytcfg: Extraction.YtCfg {
        get async throws {
            if let cached = _ytcfg {
                return cached
            }

            YouTube.loadDiskCacheIfNeeded()
            if skipAvailabilityCheck, let cached = YouTube.__ytcfg {
                _ytcfg = cached
                return cached
            }

            _ytcfg = try await Extraction.extractYtCfg(from: watchHTML)
            YouTube.__ytcfg = _ytcfg
            return _ytcfg!
        }
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /// Returns a list of streams if they have been initialized.
    /// If the streams have not been initialized, finds all relevant streams and initializes them.
    public var streams: [Stream] {
        get async throws {
            do {
                return try await extractStreams()
            } catch {
                // Any failure with the warm path engaged probably means the persisted
                // ytcfg / js / signatureTimestamp went stale (YouTube rotates them).
                // Wipe everything and retry once on the cold path before giving up.
                guard skipAvailabilityCheck else { throw error }
                print("YouTubeKit warm-path extraction failed (\(error)); invalidating caches and retrying cold")
                _watchHTML = nil
                _embedHTML = nil
                _js = nil
                _jsURL = nil
                _ytcfg = nil
                _signatureTimestamp = nil
                _videoInfos = nil
                _ageRestricted = nil
                _fmtStreams = nil
                YouTube.invalidateAllCaches()
                skipAvailabilityCheck = false
                defer { skipAvailabilityCheck = true }
                return try await extractStreams()
            }
        }
    }

    private func extractStreams() async throws -> [Stream] {
        if !skipAvailabilityCheck {
            try await checkAvailability()
        }
        if let cached = _fmtStreams {
            return cached
        }

        let result = try await Task.retry(with: methods) { method in
                switch method {
#if canImport(JavaScriptCore)
                case .local:
                    let allStreamingData = try await self.streamingData
                    let videoInfos = try await self.videoInfos
                    
                    var streams = [Stream]()
                    var existingITags = Set<Int>()
                    
                    func process(streamingData: InnerTube.StreamingData, videoInfo: InnerTube.VideoInfo) async throws {

                        var streamManifest = Extraction.applyDescrambler(streamData: streamingData)

                        // Narrow the manifest before signing — large win for cold-extract latency.
                        if let filter = self.itagFilter {
                            streamManifest = streamManifest.filter { filter($0.itag) }
                        }

                        do {
                            try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
                        } catch {
                            // Signature failed — base.js probably rotated. Wipe both static
                            // and persisted caches, fall back to the full pipeline, and retry.
                            _js = nil
                            _jsURL = nil
                            _ytcfg = nil
                            _signatureTimestamp = nil
                            YouTube.invalidateAllCaches()
                            // Force re-fetch on the slow path even if we were skipping availability.
                            let previousSkip = self.skipAvailabilityCheck
                            self.skipAvailabilityCheck = false
                            defer { self.skipAvailabilityCheck = previousSkip }
                            try await Extraction.applySignature(streamManifest: &streamManifest, videoInfo: videoInfo, js: js)
                        }
                        
                        // filter out dubbed audio tracks
                        streamManifest = Extraction.filterOutDubbedAudio(streamManifest: streamManifest)
                        
                        let newStreams = streamManifest.compactMap { try? Stream(format: $0) }
                        
                        // make sure only one stream per itag exists
                        for stream in newStreams {
                            if existingITags.insert(stream.itag.itag).inserted {
                                streams.append(stream)
                            }
                        }
                    }
                    
                    for (streamingData, videoInfo) in zip(allStreamingData, videoInfos) {
                        try await process(streamingData: streamingData, videoInfo: videoInfo)
                    }
                    
                    // if no progressive (audio+video) tracks were found, try to do one more call to maybe get them
                    if !streams.contains(where: { $0.includesVideoAndAudioTrack }) {
                        if let videoInfo = try? await loadAdditionalVideoInfos(forClient: .mediaConnectFrontend), let streamingData = videoInfo.streamingData {
                            os_log("Found no progressive streams. Called mediaConnectFrontend client to get additional video infos", log: log, type: .info)
                            try await process(streamingData: streamingData, videoInfo: videoInfo)
                        }
                    }

                    // Streams extracted successfully — persist the player JS + ytcfg
                    // so the next launch can skip watchHTML entirely.
                    YouTube.saveDiskCache()

                    return streams
#endif
                    
                case .remote(let serverURL):
                    let remoteClient = RemoteYouTubeClient(serverURL: serverURL)
                    let remoteStreams = try await remoteClient.extractStreams(forVideoID: videoID)
                    
                    return remoteStreams.compactMap { try? Stream(remoteStream: $0) }
                }
            }

            _fmtStreams = result
            return result
    }

    /// Returns a list of live streams - currently only HLS supported
    /// - Note: Currently doesn't respect `method` set. It always uses `.local`
    public var livestreams: [Livestream] {
        get async throws {
            var livestreams = [Livestream]()
            let hlsURLs = try await streamingData.compactMap { $0.hlsManifestUrl }.compactMap { URL(string: $0) }
            livestreams.append(contentsOf: hlsURLs.map { Livestream(url: $0, streamType: .hls) })
            return livestreams
        }
    }

    /// streaming data from video info
    var streamingData: [InnerTube.StreamingData] {
        get async throws {
            let streamingData = try await videoInfos.compactMap { $0.streamingData }
            if !streamingData.isEmpty {
                return streamingData
            } else {
                try await bypassAgeGate()
                let streamingData = try await videoInfos.compactMap { $0.streamingData }
                if !streamingData.isEmpty {
                    return streamingData
                } else {
                    throw YouTubeKitError.extractError
                }
            }
        }
    }

    /// Video details from video info.
    var videoDetails: [InnerTube.VideoInfo.VideoDetails] {
        get async throws {
            try await videoInfos.compactMap { $0.videoDetails }
        }
    }
    
    var videoInfos: [InnerTube.VideoInfo] {
        get async throws {
            if let cached = _videoInfos {
                return cached
            }
            
            // try extracting video infos from watch html directly as well
            let watchVideoInfoTask = Task<InnerTube.VideoInfo?, Never> { [log] in
                do {
                    return nil //try await Extraction.getVideoInfo(fromHTML: watchHTML)  // (temporarily disabled)
                } catch let error {
                    os_log("Couldn't extract video info from main watch html: %{public}@", log: log, type: .debug, error.localizedDescription)
                    return nil
                }
            }

            let signatureTimestamp = try await signatureTimestamp
            let ytcfg = try await ytcfg
            
            // Sequential client fallback. Try androidVR first (typically returns the
            // full AVC1 set in one call). Only fall through to web / webSafari if the
            // caller's `responseSatisfied` check rejects the response.
            //
            // Without `responseSatisfied` set, the first successful client wins —
            // matches the old "happy path" but pays only 1 round-trip on cache-warm runs.
            let clientPriority: [InnerTube.ClientType] = [.androidVR, .web, .webSafari]

            var videoInfos = [InnerTube.VideoInfo]()
            var errors = [Error]()

            for client in clientPriority {
                let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
                do {
                    let response = try await innertube.player(videoID: videoID)

                    // InnerTube clients occasionally return a player response for a
                    // different videoID (ytcfg/cookie drift). Skip without breaking
                    // so we try the next client instead of accepting a bogus response.
                    guard response.videoDetails?.videoId == videoID else {
                        os_log("Skipping wrong-video response from %{public}@", log: log, type: .info, client.rawValue)
                        continue
                    }

                    videoInfos.append(response)

                    // Stop as soon as we get a valid response the caller considers sufficient.
                    let adaptiveItags = response.streamingData?.adaptiveFormats?.map(\.itag) ?? []
                    let muxedItags = response.streamingData?.formats?.map(\.itag) ?? []
                    let allItags = adaptiveItags + muxedItags
                    if let check = self.responseSatisfied {
                        if check(allItags) { break }
                    } else {
                        break
                    }
                } catch {
                    errors.append(error)
                }
            }
            
            // append potentially extracted video info (with least priority)
            if let watchVideoInfo = await watchVideoInfoTask.value {
                videoInfos.append(watchVideoInfo)
            }
            
            // remove video infos with incorrect videoID
            for (i, videoInfo) in videoInfos.enumerated() where videoInfo.videoDetails?.videoId != videoID {
                os_log("Skipping player response from client %{public}i. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, i, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            }
            videoInfos = videoInfos.filter { $0.videoDetails?.videoId == videoID }
            
            if videoInfos.isEmpty {
                throw errors.first ?? YouTubeKitError.extractError
            }
            
            _videoInfos = videoInfos
            return videoInfos
        }
    }
    
    private func loadAdditionalVideoInfos(forClient client: InnerTube.ClientType) async throws -> InnerTube.VideoInfo {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = try await ytcfg
        let innertube = InnerTube(client: client, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
        let videoInfo = try await innertube.player(videoID: videoID)
        
        // ignore if incorrect videoID
        if videoInfo.videoDetails?.videoId != videoID {
            os_log("Skipping player response from %{public}@ client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, client.rawValue, videoInfo.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }
        
        return videoInfo
    }
    
    private func bypassAgeGate() async throws {
        let signatureTimestamp = try await signatureTimestamp
        let ytcfg = try await ytcfg
        let innertube = InnerTube(client: .webCreator, signatureTimestamp: signatureTimestamp, ytcfg: ytcfg, useOAuth: useOAuth, allowCache: allowOAuthCache)
        let innertubeResponse = try await innertube.player(videoID: videoID)

        if innertubeResponse.playabilityStatus?.status == "UNPLAYABLE" || innertubeResponse.playabilityStatus?.status == "LOGIN_REQUIRED" {
            throw YouTubeKitError.videoAgeRestricted
        }

        if innertubeResponse.videoDetails?.videoId != videoID {
            os_log("Skipping player response from webCreator client. Got player response for %{public}@ instead of %{public}@", log: log, type: .info, innertubeResponse.videoDetails?.videoId ?? "nil", videoID)
            throw YouTubeKitError.extractError
        }

        _videoInfos = [innertubeResponse]
    }
    
    /// Interface to query both adaptive (DASH) and progressive streams.
    /*public var streams: StreamQuery {
        get async throws {
            //try await checkAvailability()
            return StreamQuery(fmtStreams: try await fmtStreams)
        }
    }*/
    
}
