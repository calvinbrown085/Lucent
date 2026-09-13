import Foundation

/// Sample lineup and listings that back **demo mode**.
///
/// Typing `demo` into the HDHomeRun address field switches `AppModel` off the
/// network entirely: no LAN scan, no Gracenote/XMLTV fetch, no VLC. Everything
/// the UI needs — a lineup, a week of listings, a simulated stream — is
/// generated locally, so App Store review can exercise the whole app without a
/// tuner on the network.
///
/// Rows are keyed by `demo.<guideNumber>` xmltvIDs so they can never collide
/// with real Gracenote/XMLTV cache rows, and so
/// `EPGStore.deletePrograms(channelXmltvIDPrefix:)` removes exactly the demo
/// listings when the user leaves demo mode.
///
/// Everything here is fictional: the stations, the shows, and the descriptions.
public enum DemoContent {
    /// What the user types into the device-address field to turn demo mode on.
    public static let addressToken = "demo"
    /// Prefix on every demo `channelXmltvID`. Also the purge key.
    public static let xmltvIDPrefix = "demo."
    public static let deviceID = "DEMO-0000001"

    /// How far back listings are generated, so "now" is never the first cell in
    /// a row and in-progress programs have a real start time behind them.
    public static let lookbackHours = 12
    /// Days of forward listings — matches the Gracenote path's 7-day window.
    public static let forwardDays = 7

    public static func isDemoAddress(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(addressToken) == .orderedSame
    }

    public static func xmltvID(forGuideNumber guideNumber: String) -> String {
        xmltvIDPrefix + guideNumber
    }

    /// Stands in for the `discover.json` payload of a real tuner.
    public static var deviceInfo: HDHRDeviceInfo {
        HDHRDeviceInfo(
            DeviceID: deviceID,
            BaseURL: nil,
            ModelNumber: "Lucent Demo Tuner",
            FirmwareName: "demo-1.0",
            TunerCount: 2,
            LineupURL: nil
        )
    }

    /// The demo lineup. `streamURL` is a placeholder — demo mode never hands it
    /// to VLC; `PlayerCoordinator` short-circuits and the UI renders a simulated
    /// picture instead.
    public static func channels() -> [Channel] {
        lineup.map { spec in
            Channel(
                id: "hdhr:\(deviceID):\(spec.number)",
                source: .hdhomerun(deviceID: deviceID),
                guideNumber: spec.number,
                guideName: spec.name,
                streamURL: URL(string: "lucent-demo://channel/\(spec.number)")!,
                isHD: spec.isHD,
                xmltvID: xmltvID(forGuideNumber: spec.number)
            )
        }
    }

    /// A week of listings for every demo channel, contiguous and gap-free.
    ///
    /// Deterministic for a given `anchor`: schedules start on the half hour, so
    /// program ids (which embed the start time) are stable across repeated
    /// generation within the same half hour and re-ingest as upserts.
    public static func programs(anchor: Date = .now) -> [Program] {
        let windowStart = snapToHalfHour(anchor).addingTimeInterval(-Double(lookbackHours) * 3600)
        let windowEnd = snapToHalfHour(anchor).addingTimeInterval(Double(forwardDays) * 86_400)

        var out: [Program] = []
        out.reserveCapacity(lineup.count * 260)

        for spec in lineup {
            let channelID = xmltvID(forGuideNumber: spec.number)
            var cursor = windowStart
            var slot = 0
            var airings: [String: Int] = [:]

            while cursor < windowEnd {
                let show = spec.shows[slot % spec.shows.count]
                let airing = airings[show.title, default: 0]
                airings[show.title] = airing + 1
                let stop = cursor.addingTimeInterval(Double(show.minutes) * 60)

                var subtitle: String?
                var episodeNumber: String?
                if !show.episodes.isEmpty {
                    subtitle = show.episodes[airing % show.episodes.count]
                    let season = 1 + airing / show.episodes.count
                    let episode = 1 + airing % show.episodes.count
                    episodeNumber = "S\(season)E\(episode)"
                }

                out.append(
                    Program(
                        id: "demo:\(channelID):\(Int(cursor.timeIntervalSince1970))",
                        channelXmltvID: channelID,
                        title: show.title,
                        subtitle: subtitle,
                        desc: show.desc,
                        start: cursor,
                        stop: stop,
                        categories: [show.category],
                        episodeNumber: episodeNumber,
                        // Roughly one airing in three is a first run — enough
                        // NEW badges in the guide to look alive, not so many
                        // they stop meaning anything.
                        isNew: !show.episodes.isEmpty && airing % 3 == 0,
                        isLive: show.isLive,
                        rating: show.rating,
                        year: show.year,
                        credits: show.credits
                    )
                )

                cursor = stop
                slot += 1
            }
        }
        return out
    }

    /// The same listings shaped as an ingest stream, so demo mode feeds
    /// `EPGStore.ingest` through the identical path as Gracenote and XMLTV.
    public static func events(anchor: Date = .now) -> AsyncThrowingStream<XMLTVEvent, Error> {
        let rows = programs(anchor: anchor)
        let specs = lineup
        return AsyncThrowingStream { continuation in
            for spec in specs {
                continuation.yield(
                    .channel(
                        id: xmltvID(forGuideNumber: spec.number),
                        displayNames: [spec.name, spec.number],
                        iconURL: nil
                    )
                )
            }
            for program in rows {
                continuation.yield(.program(program))
            }
            continuation.finish()
        }
    }

    // MARK: - Lineup definition

    struct Show {
        let title: String
        let desc: String
        let category: String
        let minutes: Int
        var episodes: [String] = []
        var rating: String?
        var isLive: Bool = false
        var year: Int? = nil
        /// Fictional cast and crew, so the detail screen has something to show.
        var credits: [String] = []
    }

    struct ChannelSpec {
        let number: String
        let name: String
        var isHD: Bool = true
        let shows: [Show]
    }

    /// 14 fictional stations, including two subchannels, so the guide grid and
    /// the channel wall both need to scroll.
    static let lineup: [ChannelSpec] = [
        ChannelSpec(number: "2.1", name: "Northlight News", shows: [
            Show(title: "Northlight Morning", desc: "The day's headlines, weather and traffic from the Northlight newsroom.", category: "News", minutes: 120, rating: "TV-G", isLive: true),
            Show(title: "Capitol Desk", desc: "Reporters break down the week in state and national politics.", category: "News", minutes: 60, episodes: ["Budget Season", "The Ballot Question", "Recess Week", "Confirmation Fight"], rating: "TV-G"),
            Show(title: "Northlight at Noon", desc: "Midday headlines and consumer reporting.", category: "News", minutes: 60, rating: "TV-G", isLive: true),
            Show(title: "The Long Read", desc: "One story, reported in depth, with the people at the center of it.", category: "News", minutes: 60, episodes: ["The Last Ferry", "Water Rights", "After the Mill Closed", "Two Winters"], rating: "TV-PG"),
            Show(title: "Northlight Evening", desc: "The evening newscast, anchored live.", category: "News", minutes: 60, rating: "TV-G", isLive: true),
            Show(title: "Crossfire Hour", desc: "A moderated debate on the story everyone is arguing about.", category: "News", minutes: 60, episodes: ["Housing", "Tuition", "The Freeway Plan", "Term Limits"], rating: "TV-PG"),
            Show(title: "Night Watch", desc: "Overnight headlines, updated as they break.", category: "News", minutes: 120, rating: "TV-G", isLive: true),
        ]),
        ChannelSpec(number: "2.2", name: "Northlight Weather", isHD: false, shows: [
            Show(title: "Radar Now", desc: "Continuous local radar, forecast and travel conditions.", category: "News", minutes: 30, rating: "TV-G", isLive: true),
            Show(title: "Seven-Day Outlook", desc: "The week ahead, region by region.", category: "News", minutes: 30, rating: "TV-G", isLive: true),
            Show(title: "Storm Files", desc: "How the region's worst weather came together, hour by hour.", category: "Documentary", minutes: 30, episodes: ["The Ice Storm", "Flood Stage", "Wind Event", "The Quiet Blizzard"], rating: "TV-PG"),
        ]),
        ChannelSpec(number: "4.1", name: "Aurora", shows: [
            Show(title: "Kettle & Crumb", desc: "Bakers compete under a countdown clock and a very literal judge.", category: "Reality", minutes: 60, episodes: ["Laminate Week", "Sugar Work", "Bread Week", "The Final Bake"], rating: "TV-G"),
            Show(title: "The Ninth Floor", desc: "A workplace comedy about the only department nobody can shut down.", category: "Comedy", minutes: 30, episodes: ["Budget Freeze", "The Reorg", "Fire Drill", "Offsite", "Performance Review", "The New Hire"], rating: "TV-14"),
            Show(title: "Neighbors of Vale Street", desc: "Two families, one cul-de-sac, and a fence dispute that will not end.", category: "Comedy", minutes: 30, episodes: ["The Survey", "Block Party", "Permit Pending", "Snow Day"], rating: "TV-PG"),
            Show(title: "Lantern Bay", desc: "A harbor town drama about the people who stayed.", category: "Drama", minutes: 60, episodes: ["Slack Tide", "The Buyer", "Nor'easter", "Salvage Rights", "Closing Day"], rating: "TV-14", credits: ["Sable Northway", "Corin Ashby", "Femi Larkspur"]),
            Show(title: "Second Serve", desc: "A retired champion takes over a struggling public tennis club.", category: "Drama", minutes: 60, episodes: ["Court Two", "The Wall", "Match Point", "Off Season"], rating: "TV-PG"),
            Show(title: "Aurora Tonight", desc: "Interviews, sketches and live music from the Aurora stage.", category: "Comedy", minutes: 60, episodes: ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"], rating: "TV-14", isLive: true),
        ]),
        ChannelSpec(number: "5.1", name: "Beacon Sports", shows: [
            Show(title: "Beacon SportsDesk", desc: "Scores, highlights and analysis from every league we cover.", category: "Sports", minutes: 60, rating: "TV-G", isLive: true),
            Show(title: "Harbor League Baseball", desc: "Live regular-season baseball from the Harbor League.", category: "Sports", minutes: 180, episodes: ["Anchors at Foundry", "Foundry at Cliffside", "Cliffside at Anchors", "Anchors at Rail Yard"], rating: "TV-G", isLive: true),
            Show(title: "Inside the Paint", desc: "Coaches and analysts break down the basketball week.", category: "Sports", minutes: 60, episodes: ["Trade Window", "Rookie Wall", "Playoff Push", "Draft Board"], rating: "TV-G"),
            Show(title: "Coastal Football Live", desc: "Live college football from the Coastal Conference.", category: "Sports", minutes: 180, episodes: ["Mariners at Summit", "Summit at Ridgeway", "Ridgeway at Mariners", "Rivalry Week"], rating: "TV-G", isLive: true),
            Show(title: "The Turn", desc: "Golf, long-form: one round, four players, no ad breaks.", category: "Sports", minutes: 120, episodes: ["Round One", "Round Two", "Moving Day", "Final Round"], rating: "TV-G"),
            Show(title: "Beacon Overtime", desc: "Postgame reaction and the night's best finishes.", category: "Sports", minutes: 60, rating: "TV-G", isLive: true),
        ]),
        ChannelSpec(number: "7.1", name: "Prism Movies", shows: [
            Show(title: "The Longest Winter", desc: "A snowbound rescue team is forced to choose who they can reach first.", category: "Movie", minutes: 120, rating: "PG-13", year: 2021, credits: ["Ines Marlow", "Teodor Vance", "Priya Sandoval"]),
            Show(title: "Copper Line", desc: "A telephone lineman stumbles into the biggest story of 1961.", category: "Movie", minutes: 105, rating: "PG", year: 2018, credits: ["Rafael Okonkwo", "Della Hartigan"]),
            Show(title: "Paper Moonlight", desc: "Two strangers spend one night trying to return a suitcase full of letters.", category: "Movie", minutes: 105, rating: "PG"),
            Show(title: "Undertow County", desc: "A sheriff's investigation of a drowning unravels a company town.", category: "Movie", minutes: 135, rating: "R", year: 2023, credits: ["Maren Quill", "Josiah Bellweather", "Anouk Ferris"]),
            Show(title: "Glasshouse", desc: "An architect's award-winning building starts telling on its owners.", category: "Movie", minutes: 120, rating: "PG-13"),
            Show(title: "The Understudy", desc: "A backstage comedy about the only person who knows every line.", category: "Movie", minutes: 105, rating: "PG-13"),
        ]),
        ChannelSpec(number: "9.1", name: "Cascade Drama", shows: [
            Show(title: "Ward Nine", desc: "A county hospital's night shift, told in real time.", category: "Drama", minutes: 60, episodes: ["Triage", "The Long Shift", "Code Silver", "Discharge", "Handoff", "Census Full"], rating: "TV-14"),
            Show(title: "Circuit Court", desc: "A rural judge, a new clerk, and a docket nobody wants.", category: "Drama", minutes: 60, episodes: ["Continuance", "Voir Dire", "The Plea", "Sentencing", "Appeal"], rating: "TV-14"),
            Show(title: "Deep Field", desc: "Astronomers at a remote observatory find something that shouldn't be there.", category: "Drama", minutes: 60, episodes: ["First Light", "Seeing", "Occultation", "Redshift", "The Signal"], rating: "TV-14"),
            Show(title: "Mercy Street Station", desc: "An engine company adjusts to a new captain and an old grudge.", category: "Drama", minutes: 60, episodes: ["Probationary", "Two-Alarm", "Mutual Aid", "The Board"], rating: "TV-14"),
        ]),
        ChannelSpec(number: "11.1", name: "Vista Kids", shows: [
            Show(title: "Tide Pool Detectives", desc: "Three friends solve small mysteries along the shoreline.", category: "Kids", minutes: 30, episodes: ["The Missing Bucket", "Hermit Crab Hotel", "Low Tide Map", "Whose Footprint?"], rating: "TV-Y"),
            Show(title: "Marlo Builds It", desc: "Marlo takes on a new building project and one very bad plan.", category: "Kids", minutes: 30, episodes: ["A Bridge for Bo", "The Wobbly Chair", "Rain Catcher", "Treehouse Day"], rating: "TV-Y"),
            Show(title: "Counting Cricket", desc: "Songs and puzzles about numbers, shapes and patterns.", category: "Kids", minutes: 30, episodes: ["Tens", "Shapes at Home", "Odd One Out", "Patterns Everywhere"], rating: "TV-Y"),
            Show(title: "The Story Wagon", desc: "A traveling library brings a different tale to a different town.", category: "Kids", minutes: 30, episodes: ["Riverbend", "Copperfield", "Fog Hollow", "Sandy Point"], rating: "TV-Y"),
        ]),
        ChannelSpec(number: "11.2", name: "Vista Retro", isHD: false, shows: [
            Show(title: "The Pemberton Hour", desc: "Classic variety: sketches, songs and the house band.", category: "Comedy", minutes: 30, episodes: ["Season Premiere", "The Duet", "Backstage", "Finale"], rating: "TV-G"),
            Show(title: "Hollis & Vine", desc: "A vintage sitcom about two detectives who share one office.", category: "Comedy", minutes: 30, episodes: ["The Stakeout", "Case of the Missing Fedora", "Vacation Days", "The Promotion"], rating: "TV-G"),
            Show(title: "Airwaves", desc: "Life at a small-town radio station in 1958.", category: "Comedy", minutes: 30, episodes: ["Sign-On", "The Sponsor", "Dead Air", "Ratings Week"], rating: "TV-G"),
        ]),
        ChannelSpec(number: "13.1", name: "Meridian Public", shows: [
            Show(title: "The Making Of", desc: "How ordinary objects are designed, built and shipped.", category: "Documentary", minutes: 60, episodes: ["Bicycles", "Pianos", "Rope", "Window Glass"], rating: "TV-G"),
            Show(title: "Field Notes", desc: "A naturalist's year across one watershed.", category: "Documentary", minutes: 60, episodes: ["Spring Melt", "High Summer", "First Frost", "Under Ice"], rating: "TV-G"),
            Show(title: "Meridian Theatre", desc: "Filmed stage productions from regional companies.", category: "Drama", minutes: 120, episodes: ["The Inheritors", "Low Country", "Two Rooms", "The Understudy's Tale"], rating: "TV-PG"),
            Show(title: "Table Talk", desc: "Long-form conversation with a writer, a builder and a cook.", category: "Documentary", minutes: 60, episodes: ["The Archivist", "The Boatwright", "The Baker", "The Cartographer"], rating: "TV-G"),
        ]),
        ChannelSpec(number: "20.1", name: "Solstice Classics", shows: [
            Show(title: "Night Train to Ellery", desc: "1949. A conductor, a stolen ledger and eleven stops until dawn.", category: "Movie", minutes: 120, rating: "TV-PG", year: 1949, credits: ["Hollis Crane", "Vivian Marsh", "Edmund Pell"]),
            Show(title: "The Bright Hotel", desc: "A postwar romance set entirely in a hotel lobby.", category: "Movie", minutes: 120, rating: "TV-G", year: 1952, credits: ["Lorna Whitfield", "Casimir Dunne"]),
            Show(title: "Wire and Water", desc: "Engineers race a flood to finish a dam in 1936.", category: "Movie", minutes: 120, rating: "TV-PG"),
            Show(title: "Six Feet of Rope", desc: "A western about a sheriff who refuses to hold a hanging.", category: "Movie", minutes: 120, rating: "TV-PG"),
        ]),
        ChannelSpec(number: "26.1", name: "Harbor Life", shows: [
            Show(title: "One Pot", desc: "Dinner, start to finish, in a single pan.", category: "Reality", minutes: 30, episodes: ["Braise", "Weeknight Fish", "Beans", "Sunday Sauce"], rating: "TV-G"),
            Show(title: "Small House, Big Fix", desc: "Renovating houses under 900 square feet.", category: "Reality", minutes: 60, episodes: ["The Cottage", "Row House", "The Cabin", "Above the Shop"], rating: "TV-G"),
            Show(title: "Market Day", desc: "One market, one budget, one meal for eight.", category: "Reality", minutes: 30, episodes: ["Harbor Market", "The Co-op", "Winter Stalls", "Roadside"], rating: "TV-G"),
            Show(title: "Garden Hours", desc: "Slow, practical gardening through the whole season.", category: "Reality", minutes: 60, episodes: ["Beds", "Water", "Pests", "Putting It Down"], rating: "TV-G"),
        ]),
        ChannelSpec(number: "33.1", name: "Orbit Science", shows: [
            Show(title: "Orbit", desc: "What's launching, what's landing and what it's for.", category: "Documentary", minutes: 60, episodes: ["Low Earth", "The Far Side", "Sample Return", "Station Life"], rating: "TV-G"),
            Show(title: "Very Large Machines", desc: "The biggest instruments humans have built, and the questions they answer.", category: "Documentary", minutes: 60, episodes: ["The Collider", "The Array", "The Drill", "The Telescope"], rating: "TV-G"),
            Show(title: "Failure Analysis", desc: "Engineers reconstruct what went wrong, and what changed after.", category: "Documentary", minutes: 60, episodes: ["The Bridge", "The Tank", "The Turbine", "The Runway"], rating: "TV-PG"),
            Show(title: "Small Worlds", desc: "Microscopy, close up and slowed down.", category: "Documentary", minutes: 30, episodes: ["Pond Water", "Frost", "Wing Scales", "Yeast"], rating: "TV-G"),
        ]),
        ChannelSpec(number: "41.1", name: "Cobalt Music", shows: [
            Show(title: "Live at the Foundry", desc: "Full concert sets recorded at the Foundry stage.", category: "Music", minutes: 60, episodes: ["Night One", "Night Two", "Night Three", "Encore"], rating: "TV-PG", isLive: true),
            Show(title: "Liner Notes", desc: "One record, taken apart by the people who made it.", category: "Documentary", minutes: 60, episodes: ["The Debut", "The Difficult Second", "The Live Album", "The Reunion"], rating: "TV-PG"),
            Show(title: "Cobalt Countdown", desc: "This week's most-played, counted down.", category: "Music", minutes: 120, rating: "TV-PG"),
        ]),
        ChannelSpec(number: "50.1", name: "Summit Outdoors", shows: [
            Show(title: "Trailhead", desc: "A long hike, filmed end to end, with the people who maintain it.", category: "Documentary", minutes: 60, episodes: ["The Ridge", "River Crossing", "Above Tree Line", "The Descent"], rating: "TV-G"),
            Show(title: "Cold Water", desc: "Rowing, paddling and swimming where the water never warms up.", category: "Sports", minutes: 30, episodes: ["The Estuary", "Sea Ice", "Spring Melt", "The Crossing"], rating: "TV-G"),
            Show(title: "Backcountry Kitchen", desc: "Real food, cooked twelve miles from a road.", category: "Reality", minutes: 30, episodes: ["Base Camp", "Two-Day Menu", "Fire Ban", "Winter Camp"], rating: "TV-G"),
            Show(title: "The Long Way", desc: "Crossing a country by the slowest route available.", category: "Documentary", minutes: 120, episodes: ["Coast to Divide", "The Divide", "Prairie", "The Last Hundred"], rating: "TV-PG"),
        ]),
    ]

    private static func snapToHalfHour(_ date: Date) -> Date {
        let interval: TimeInterval = 1800
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / interval).rounded(.down) * interval)
    }
}
