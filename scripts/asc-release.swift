#!/usr/bin/env swift
//
// App Store Connect release driver for Lucent. Given a build that
// scripts/testflight.sh already uploaded, this:
//
//   1. waits for the build to finish processing,
//   2. answers export compliance on the build if App Store Connect asks,
//   3. creates (or reuses) the App Store version for the platform,
//   4. writes the "What's New" text into the en-US localization,
//   5. attaches the build to the version,
//   6. creates a review submission and submits it.
//
// Normally invoked via scripts/release.sh; direct usage:
//
//   swift scripts/asc-release.swift --platform TV_OS --version 1.2 \
//       --build 202609141530 --notes build/release-notes-tvos.txt [--no-submit]
//
//   swift scripts/asc-release.swift --check        # auth + print versions, no changes
//
// Auth (App Store Connect API key, App Manager role or higher):
//   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_XXXX.p8)

import Foundation
import CryptoKit

// MARK: - CLI

struct Options {
    var platform = "TV_OS"          // TV_OS | IOS
    var bundleID = "CalvinBrown.Lucent"
    var version = ""
    var build = ""
    var notesPath = ""
    var submit = true
    var check = false
    var timeoutMinutes = 45
    var pollSeconds = 60
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func take() -> String {
        guard !args.isEmpty else { fail("missing value after \(CommandLine.arguments.last ?? "")") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--platform": o.platform = take().uppercased()
        case "--bundle-id": o.bundleID = take()
        case "--version": o.version = take()
        case "--build": o.build = take()
        case "--notes": o.notesPath = take()
        case "--no-submit": o.submit = false
        case "--check": o.check = true
        case "--timeout": o.timeoutMinutes = Int(take()) ?? 45
        case "--poll": o.pollSeconds = Int(take()) ?? 60
        case "-h", "--help":
            print("usage: asc-release.swift --platform TV_OS|IOS --version X.Y --build N --notes FILE [--no-submit] [--timeout MIN]")
            print("       asc-release.swift --check")
            exit(0)
        default: fail("unknown argument \(a)")
        }
    }
    if !o.check {
        guard ["TV_OS", "IOS"].contains(o.platform) else { fail("--platform must be TV_OS or IOS") }
        guard !o.version.isEmpty else { fail("--version required") }
        guard !o.build.isEmpty else { fail("--build required") }
        guard !o.notesPath.isEmpty else { fail("--notes required") }
    }
    return o
}

func log(_ s: String) { print("▶ \(s)"); fflush(stdout) }
func warn(_ s: String) { print("⚠︎ \(s)"); fflush(stdout) }
func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("✖ \(s)\n".utf8))
    exit(1)
}

// MARK: - Auth (ES256 JWT)

struct Credentials {
    let keyID: String
    let issuerID: String
    let privateKey: P256.Signing.PrivateKey

    static func fromEnvironment() -> Credentials {
        let env = ProcessInfo.processInfo.environment
        guard let kid = env["ASC_KEY_ID"], let iss = env["ASC_ISSUER_ID"], let path = env["ASC_KEY_PATH"] else {
            fail("ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH must be set (App Store Connect API key)")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            fail("cannot read API key at \(expanded)")
        }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            fail("API key at \(expanded) is not a valid P-256 private key (.p8)")
        }
        return Credentials(keyID: kid, issuerID: iss, privateKey: key)
    }

    func token() -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": issuerID, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"]
        let h = b64url(try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let p = b64url(try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = Data("\(h).\(p)".utf8)
        let sig = try! privateKey.signature(for: signingInput)
        return "\(h).\(p).\(b64url(sig.rawRepresentation))"
    }
}

// MARK: - HTTP

struct APIError: Error, CustomStringConvertible {
    let status: Int
    let code: String
    let title: String
    let detail: String
    var description: String { "HTTP \(status) \(code): \(title) — \(detail)" }
}

final class ASCClient {
    let base = URL(string: "https://api.appstoreconnect.apple.com")!
    let creds: Credentials
    private var cachedToken: (value: String, issued: Date)?

    init(creds: Credentials) { self.creds = creds }

    private func bearer() -> String {
        if let t = cachedToken, Date().timeIntervalSince(t.issued) < 10 * 60 { return t.value }
        let t = creds.token()
        cachedToken = (t, Date())
        return t
    }

    @discardableResult
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> [String: Any] {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(bearer())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in result = (d, r, e); sem.signal() }.resume()
        sem.wait()

        if let e = result.2 { throw APIError(status: 0, code: "transport", title: "request failed", detail: e.localizedDescription) }
        let http = result.1 as! HTTPURLResponse
        let data = result.0 ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            let first = (json["errors"] as? [[String: Any]])?.first ?? [:]
            throw APIError(
                status: http.statusCode,
                code: first["code"] as? String ?? "unknown",
                title: first["title"] as? String ?? "error",
                detail: first["detail"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            )
        }
        return json
    }

    func list(_ path: String, query: [String: String] = [:]) throws -> [[String: Any]] {
        try request("GET", path, query: query)["data"] as? [[String: Any]] ?? []
    }
}

func attr(_ node: [String: Any], _ key: String) -> Any? {
    (node["attributes"] as? [String: Any])?[key]
}
func id(_ node: [String: Any]) -> String { node["id"] as? String ?? "" }

func platformLabel(_ p: String) -> String { p == "TV_OS" ? "tvOS" : "iOS" }

// MARK: - Steps

func findApp(_ api: ASCClient, bundleID: String) throws -> [String: Any] {
    let apps = try api.list("/v1/apps", query: ["filter[bundleId]": bundleID, "fields[apps]": "name,bundleId"])
    guard let app = apps.first else { fail("no app with bundle id \(bundleID) visible to this API key") }
    return app
}

func waitForBuild(_ api: ASCClient, appID: String, platform: String, build: String, timeoutMinutes: Int, pollSeconds: Int) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutMinutes * 60))
    var announced = false
    while true {
        let builds = try api.list("/v1/builds", query: [
            "filter[app]": appID,
            "filter[version]": build,
            "filter[preReleaseVersion.platform]": platform,
            "fields[builds]": "version,processingState,usesNonExemptEncryption,expired,uploadedDate",
            "sort": "-uploadedDate",
            "limit": "5",
        ])
        if let b = builds.first(where: { (attr($0, "expired") as? Bool) != true }) {
            let state = attr(b, "processingState") as? String ?? "?"
            switch state {
            case "VALID":
                log("Build \(build) (\(platformLabel(platform))) is processed")
                return b
            case "FAILED", "INVALID":
                fail("build \(build) processing ended in state \(state) — check App Store Connect")
            default:
                if !announced { log("Build \(build) is \(state); waiting for App Store Connect to finish processing"); announced = true }
            }
        } else if !announced {
            log("Build \(build) not visible yet (upload still transferring or being ingested); waiting")
            announced = true
        }
        guard Date() < deadline else { fail("timed out after \(timeoutMinutes) min waiting for build \(build)") }
        Thread.sleep(forTimeInterval: TimeInterval(pollSeconds))
    }
}

func ensureExportCompliance(_ api: ASCClient, build: [String: Any]) throws {
    if attr(build, "usesNonExemptEncryption") == nil || attr(build, "usesNonExemptEncryption") is NSNull {
        log("Answering export compliance (no non-exempt encryption)")
        try api.request("PATCH", "/v1/builds/\(id(build))", body: [
            "data": ["type": "builds", "id": id(build), "attributes": ["usesNonExemptEncryption": false]]
        ])
    }
}

let editableStates: Set<String> = [
    "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY",
]

func versionState(_ v: [String: Any]) -> String {
    (attr(v, "appVersionState") as? String) ?? (attr(v, "appStoreState") as? String) ?? "?"
}

func ensureVersion(_ api: ASCClient, appID: String, platform: String, version: String) throws -> [String: Any] {
    let fields = "versionString,appVersionState,appStoreState,platform"
    let existing = try api.list("/v1/apps/\(appID)/appStoreVersions", query: [
        "filter[platform]": platform,
        "filter[versionString]": version,
        "fields[appStoreVersions]": fields,
    ])
    if let v = existing.first {
        let state = versionState(v)
        guard editableStates.contains(state) else {
            fail("\(platformLabel(platform)) \(version) already exists in state \(state) and cannot be edited")
        }
        log("Reusing \(platformLabel(platform)) version \(version) (\(state))")
        return v
    }
    // Refuse to pile onto a version that's already in the review pipeline.
    let inFlight = try api.list("/v1/apps/\(appID)/appStoreVersions", query: [
        "filter[platform]": platform,
        "filter[appStoreState]": "WAITING_FOR_REVIEW,IN_REVIEW,PENDING_DEVELOPER_RELEASE,PENDING_APPLE_RELEASE",
        "fields[appStoreVersions]": fields,
    ])
    if let blocking = inFlight.first {
        fail("\(platformLabel(platform)) \(attr(blocking, "versionString") ?? "?") is \(versionState(blocking)); App Store Connect only allows one version in the review pipeline per platform. Wait for it to be released or reject it first.")
    }
    log("Creating \(platformLabel(platform)) version \(version)")
    let created = try api.request("POST", "/v1/appStoreVersions", body: [
        "data": [
            "type": "appStoreVersions",
            "attributes": ["platform": platform, "versionString": version],
            "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
        ]
    ])
    return created["data"] as! [String: Any]
}

func setWhatsNew(_ api: ASCClient, versionID: String, notes: String) throws {
    let locs = try api.list("/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", query: [
        "fields[appStoreVersionLocalizations]": "locale,whatsNew"
    ])
    do {
        if let en = locs.first(where: { (attr($0, "locale") as? String) == "en-US" }) {
            log("Updating What's New (en-US)")
            try api.request("PATCH", "/v1/appStoreVersionLocalizations/\(id(en))", body: [
                "data": ["type": "appStoreVersionLocalizations", "id": id(en), "attributes": ["whatsNew": notes]]
            ])
        } else {
            log("Creating en-US localization with What's New")
            try api.request("POST", "/v1/appStoreVersionLocalizations", body: [
                "data": [
                    "type": "appStoreVersionLocalizations",
                    "attributes": ["locale": "en-US", "whatsNew": notes],
                    "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]]],
                ]
            ])
        }
    } catch let e as APIError where e.detail.localizedCaseInsensitiveContains("first version") {
        warn("App Store Connect doesn't accept What's New on an app's first version; skipping (\(e.detail))")
    }
}

func attachBuild(_ api: ASCClient, versionID: String, buildID: String) throws {
    log("Attaching build to version")
    try api.request("PATCH", "/v1/appStoreVersions/\(versionID)", body: [
        "data": [
            "type": "appStoreVersions",
            "id": versionID,
            "relationships": ["build": ["data": ["type": "builds", "id": buildID]]],
        ]
    ])
}

func submitForReview(_ api: ASCClient, appID: String, platform: String, versionID: String) throws {
    let open = try api.list("/v1/apps/\(appID)/reviewSubmissions", query: [
        "filter[platform]": platform,
        "filter[state]": "READY_FOR_REVIEW",
        "fields[reviewSubmissions]": "state,platform",
    ])
    let submission: [String: Any]
    if let s = open.first {
        log("Reusing open review submission \(id(s))")
        submission = s
    } else {
        log("Creating review submission")
        submission = try api.request("POST", "/v1/reviewSubmissions", body: [
            "data": [
                "type": "reviewSubmissions",
                "attributes": ["platform": platform],
                "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
            ]
        ])["data"] as! [String: Any]
    }
    let sid = id(submission)

    let items = try api.list("/v1/reviewSubmissions/\(sid)/items", query: [
        "include": "appStoreVersion", "fields[reviewSubmissionItems]": "state,appStoreVersion",
    ])
    let alreadyAdded = items.contains { item in
        let rel = ((item["relationships"] as? [String: Any])?["appStoreVersion"] as? [String: Any])?["data"] as? [String: Any]
        return (rel?["id"] as? String) == versionID
    }
    if !alreadyAdded {
        log("Adding version to review submission")
        try api.request("POST", "/v1/reviewSubmissionItems", body: [
            "data": [
                "type": "reviewSubmissionItems",
                "relationships": [
                    "reviewSubmission": ["data": ["type": "reviewSubmissions", "id": sid]],
                    "appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]],
                ],
            ]
        ])
    }

    log("Submitting for review")
    try api.request("PATCH", "/v1/reviewSubmissions/\(sid)", body: [
        "data": ["type": "reviewSubmissions", "id": sid, "attributes": ["submitted": true]]
    ])
}

// MARK: - Check mode

func runCheck(_ api: ASCClient, bundleID: String) throws {
    let app = try findApp(api, bundleID: bundleID)
    log("App: \(attr(app, "name") ?? "?") (\(bundleID)) id \(id(app))")
    for platform in ["TV_OS", "IOS"] {
        let versions = try api.list("/v1/apps/\(id(app))/appStoreVersions", query: [
            "filter[platform]": platform,
            "fields[appStoreVersions]": "versionString,appVersionState,appStoreState,createdDate",
            "limit": "5",
        ])
        print("  \(platformLabel(platform)) versions:")
        if versions.isEmpty { print("    (none)") }
        for v in versions { print("    \(attr(v, "versionString") ?? "?")  \(versionState(v))") }
        let builds = try api.list("/v1/builds", query: [
            "filter[app]": id(app),
            "filter[preReleaseVersion.platform]": platform,
            "fields[builds]": "version,processingState,uploadedDate",
            "sort": "-uploadedDate",
            "limit": "3",
        ])
        print("  \(platformLabel(platform)) recent builds:")
        if builds.isEmpty { print("    (none)") }
        for b in builds { print("    \(attr(b, "version") ?? "?")  \(attr(b, "processingState") ?? "?")  \(attr(b, "uploadedDate") ?? "")") }
    }
}

// MARK: - Main

let opts = parseOptions()
let api = ASCClient(creds: Credentials.fromEnvironment())

do {
    if opts.check {
        try runCheck(api, bundleID: opts.bundleID)
        exit(0)
    }

    let notes = try String(contentsOfFile: opts.notesPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !notes.isEmpty else { fail("release notes file \(opts.notesPath) is empty") }
    guard notes.count <= 4000 else { fail("What's New is limited to 4000 characters (have \(notes.count))") }

    let app = try findApp(api, bundleID: opts.bundleID)
    let appID = id(app)
    log("\(attr(app, "name") ?? "Lucent") \(opts.version) (\(opts.build)) → \(platformLabel(opts.platform))")

    let build = try waitForBuild(api, appID: appID, platform: opts.platform, build: opts.build,
                                 timeoutMinutes: opts.timeoutMinutes, pollSeconds: opts.pollSeconds)
    try ensureExportCompliance(api, build: build)

    let version = try ensureVersion(api, appID: appID, platform: opts.platform, version: opts.version)
    let versionID = id(version)
    try setWhatsNew(api, versionID: versionID, notes: notes)
    try attachBuild(api, versionID: versionID, buildID: id(build))

    if opts.submit {
        try submitForReview(api, appID: appID, platform: opts.platform, versionID: versionID)
        log("\(platformLabel(opts.platform)) \(opts.version) (\(opts.build)) submitted for review")
    } else {
        log("\(platformLabel(opts.platform)) \(opts.version) (\(opts.build)) prepared; not submitted (--no-submit)")
    }
} catch let e as APIError {
    fail(e.description)
} catch {
    fail("\(error)")
}
