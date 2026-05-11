import Foundation

public actor GracenoteIngestService {
    private let store: EPGStore
    private let client: GracenoteAPIClient
    private(set) public var lastRefresh: Date?

    /// Days of historical listings retained for the auto (Gracenote) guide. Drives
    /// both the initial backfill window and the purge cutoff.
    public static let historyDays: Int = 7

    public init(store: EPGStore, client: GracenoteAPIClient = GracenoteAPIClient()) {
        self.store = store
        self.client = client
    }

    /// Fetch listings spanning `[now − historyDays·24h, now + hours]` in 6-hour
    /// chunks, ingest each chunk into the EPG store, and prune programs that ended
    /// more than `historyDays` ago. On the first refresh per lineup the backfill
    /// runs once; subsequent refreshes only fetch the forward window, relying on
    /// the rolling daily forward fetch to keep the 7-day history populated.
    public func refresh(lineup: GracenoteLineup, hours: Int = 24, historyDays: Int = GracenoteIngestService.historyDays) async throws {
        let chunkSize = GracenoteAPIClient.chunkHours
        let anchor = Date()
        let timezoneOffset = TimeZone.current.secondsFromGMT()
        let backfillKey = Self.backfillKey(for: lineup)
        let backfillDone = UserDefaults.standard.object(forKey: backfillKey) != nil

        // Hour offsets (relative to anchor) of each chunk we need to fetch.
        // Backfill chunks come first so that if the network drops we still have
        // the most-recent-past windows ingested before bailing.
        var startOffsets: [Int] = []
        if !backfillDone {
            let backfillChunks = (historyDays * 24) / chunkSize
            for i in 0..<backfillChunks {
                startOffsets.append(-historyDays * 24 + i * chunkSize)
            }
        }
        let forwardChunks = max(1, Int((Double(hours) / Double(chunkSize)).rounded(.up)))
        for i in 0..<forwardChunks {
            startOffsets.append(i * chunkSize)
        }

        #if DEBUG
        print("[Lucent][Gracenote] refresh start lineup=\(lineup.lineupID) postal=\(lineup.postalCode) hours=\(hours) historyDays=\(historyDays) backfillDone=\(backfillDone) totalChunks=\(startOffsets.count)")
        #endif
        var totalChannels = 0
        var totalEvents = 0
        var failedOffsets: [Int] = []

        for (i, offsetHours) in startOffsets.enumerated() {
            try Task.checkCancellation()
            if i > 0 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let start = anchor.addingTimeInterval(Double(offsetHours) * 3600)
            do {
                let response = try await client.fetchChunk(
                    startingAt: start,
                    timespanHours: chunkSize,
                    timeZoneOffsetSeconds: timezoneOffset,
                    lineup: lineup
                )
                let chunkChannels = response.channels.count
                let chunkEvents = response.channels.reduce(0) { $0 + ($1.events?.count ?? 0) }
                totalChannels = max(totalChannels, chunkChannels)
                totalEvents += chunkEvents
                #if DEBUG
                let sampleIDs = response.channels.prefix(5).compactMap { Self.channelXmltvID(for: $0) }
                print("[Lucent][Gracenote] chunk \(i + 1)/\(startOffsets.count) offset=\(offsetHours)h start=\(start) channels=\(chunkChannels) events=\(chunkEvents) sampleKeys=\(sampleIDs)")
                #endif

                let stream = Self.programStream(from: response)
                try await store.ingest(stream)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedOffsets.append(offsetHours)
                #if DEBUG
                print("[Lucent][Gracenote] chunk \(i + 1)/\(startOffsets.count) offset=\(offsetHours)h FAILED: \(error) — continuing")
                #endif
            }
        }

        // Only set the one-time backfill watermark if every backfill chunk landed.
        // Otherwise a transient 429 mid-backfill would freeze permanent holes.
        if !backfillDone {
            let backfillFailedAny = failedOffsets.contains { $0 < 0 }
            if !backfillFailedAny {
                UserDefaults.standard.set(anchor, forKey: backfillKey)
            }
        }

        #if DEBUG
        print("[Lucent][Gracenote] refresh done channelsSeen=\(totalChannels) eventsSeen=\(totalEvents) failedChunks=\(failedOffsets.count)/\(startOffsets.count)")
        #endif
        lastRefresh = .now
        try? await store.purgeOlderThan(.now.addingTimeInterval(-Double(historyDays) * 24 * 3600))
    }

    /// UserDefaults key marking that the initial 7-day backfill has completed for
    /// a given lineup. Switching postal code / lineup uses a different key, so
    /// the new lineup gets its own backfill.
    private static func backfillKey(for lineup: GracenoteLineup) -> String {
        "com.calvinbrown.Lucent.gracenoteBackfillCompletedAt.\(lineup.lineupID)"
    }

    /// Test/diagnostic hook: clears the persisted backfill watermark for a lineup
    /// so the next `refresh` re-runs the historical fetch.
    public static func resetBackfill(for lineup: GracenoteLineup) {
        UserDefaults.standard.removeObject(forKey: backfillKey(for: lineup))
    }

    /// Convert a Gracenote grid response into an `XMLTVEvent` stream so it can flow
    /// through the existing `EPGStore.ingest` path unchanged.
    static func programStream(from response: GracenoteGridResponse) -> AsyncThrowingStream<XMLTVEvent, Error> {
        AsyncThrowingStream { continuation in
            for channel in response.channels {
                let xmltvID = channelXmltvID(for: channel)
                guard let xmltvID else { continue }

                if let icon = thumbnailURL(channel.thumbnail) {
                    let names = [channel.callSign, channel.affiliateName]
                        .compactMap { $0?.nilIfEmpty }
                    continuation.yield(.channel(id: xmltvID, displayNames: names, iconURL: icon))
                }

                guard let events = channel.events else { continue }
                for event in events {
                    if let program = makeProgram(channelXmltvID: xmltvID, event: event) {
                        continuation.yield(.program(program))
                    }
                }
            }
            continuation.finish()
        }
    }

    /// Gracenote's `thumbnail` field is a path like `/assets/p10001_h_h15_aa.png`
    /// served by the TMS image CDN. Resolve against the CDN host; pass through any
    /// already-absolute URL unchanged.
    static let thumbnailBaseURL = URL(string: "https://zap2it.tmsimg.com")!

    static func thumbnailURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
            return nil
        }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        return URL(string: trimmed, relativeTo: thumbnailBaseURL)?.absoluteURL
    }

    /// Use the channel number as the join key — it matches HDHR's `GuideNumber`
    /// (e.g. "8.1"), giving us subchannel-accurate program matches. Fall back to
    /// callsign and finally the opaque channelId if no number is present.
    static func channelXmltvID(for channel: GracenoteChannel) -> String? {
        if let no = channel.channelNo?.trimmingCharacters(in: .whitespaces), !no.isEmpty {
            return no
        }
        if let cs = channel.callSign?.trimmingCharacters(in: .whitespaces), !cs.isEmpty {
            return cs.uppercased()
        }
        return channel.channelId
    }

    static func makeProgram(channelXmltvID: String, event: GracenoteEvent) -> Program? {
        guard
            let start = parseDate(event.startTime),
            let stop = parseDate(event.endTime)
        else { return nil }

        let title = event.program?.title ?? ""
        let subtitle = event.program?.episodeTitle?.nilIfEmpty
        let desc = (event.program?.shortDesc ?? event.program?.longDesc)?.nilIfEmpty
        let categories = event.program?.genres?.compactMap { $0.nilIfEmpty } ?? []
        let flags = event.flag?.map { $0.lowercased() } ?? []
        let isNew = flags.contains("new")
        let isLive = flags.contains("live")
        let rating = event.rating?.nilIfEmpty

        let episodeNumber = formatEpisodeNumber(season: event.program?.season, episode: event.program?.episode)
        let stableID = event.programId ?? event.program?.id ?? "\(channelXmltvID):\(Int64(start.timeIntervalSince1970))"

        return Program(
            id: "\(channelXmltvID):\(stableID):\(Int64(start.timeIntervalSince1970))",
            channelXmltvID: channelXmltvID,
            title: title,
            subtitle: subtitle,
            desc: desc,
            start: start,
            stop: stop,
            categories: categories,
            episodeNumber: episodeNumber,
            isNew: isNew,
            isLive: isLive,
            rating: rating
        )
    }

    static func formatEpisodeNumber(season: String?, episode: String?) -> String? {
        let s = season?.nilIfEmpty
        let e = episode?.nilIfEmpty
        switch (s, e) {
        case (let s?, let e?): return "S\(s)E\(e)"
        case (nil, let e?): return "E\(e)"
        case (let s?, nil): return "S\(s)"
        default: return nil
        }
    }

    /// Gracenote responses use ISO8601 strings. Some omit seconds (`...T22:00Z`)
    /// and some include them (`...T22:00:00Z`); tolerate both, plus fractional seconds.
    static func parseDate(_ raw: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        // Compact "yyyy-MM-ddTHH:mmZ" (no seconds) is not a valid ISO8601 form for
        // ISO8601DateFormatter, so fall back to a manual format.
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return df.date(from: raw)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
