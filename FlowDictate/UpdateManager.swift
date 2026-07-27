import AppKit
import Foundation

/// Lightweight Sparkle-compatible appcast client.
///
/// Host an `appcast.xml` on Cloudflare R2 / any CDN (see PRODUCTION.md).
/// This manager checks the feed, reports status, and opens the download URL.
/// Full silent install later = embed the Sparkle framework; the feed format stays the same.
@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    /// Override with your public R2/CDN appcast URL, e.g.
    /// `https://updates.example.com/appcast.xml`
    static let defaultFeedURL = URL(string: "https://updates.flowdictate.app/appcast.xml")!

    /// Max appcast body size (prevents memory blow-up from a malicious feed).
    private static let maxFeedBytes = 512 * 1024
    private static let lastAutomaticCheckKey = "lastAutomaticUpdateCheck"

    /// Hosts allowed for the feed and download enclosure.
    private static let allowedHosts: Set<String> = [
        "updates.flowdictate.app",
        "flowdictate.app",
        "www.flowdictate.app"
    ]

    @Published private(set) var lastStatus = "Not checked"
    @Published private(set) var isChecking = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var downloadURL: URL?

    private init() {}

    func check(
        feedURL: URL = UpdateManager.defaultFeedURL,
        includePrereleases: Bool,
        openWhenAvailable: Bool = true
    ) async {
        if !openWhenAvailable,
           let last = UserDefaults.standard.object(forKey: Self.lastAutomaticCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            lastStatus = "Checked recently."
            return
        }
        isChecking = true
        lastStatus = "Checking for updates…"
        availableVersion = nil
        downloadURL = nil
        defer { isChecking = false }

        guard Self.isAllowedHTTPS(feedURL) else {
            lastStatus = "Update feed URL is not allowed."
            DiagnosticsLogger.shared.log("update: rejected feed URL host=\(feedURL.host ?? "?")")
            return
        }

        do {
            var request = URLRequest(url: feedURL)
            request.cachePolicy = openWhenAvailable ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
            request.timeoutInterval = 20
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastStatus = "Update server returned HTTP \(http.statusCode)."
                return
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < Self.maxFeedBytes else {
                    lastStatus = "Update feed is too large."
                    DiagnosticsLogger.shared.log("update: feed exceeded size limit")
                    return
                }
                data.append(byte)
            }
            if !openWhenAvailable {
                UserDefaults.standard.set(Date(), forKey: Self.lastAutomaticCheckKey)
            }

            let items = AppcastParser.parse(data)
            guard let best = items.best(includePrereleases: includePrereleases) else {
                lastStatus = "No releases found in appcast."
                return
            }

            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let releaseVersion = best.sparkleShortVersion ?? best.titleVersion
            if AppcastParser.compareVersions(releaseVersion, current) == .orderedDescending {
                availableVersion = releaseVersion
                if let url = best.enclosureURL,
                   Self.isAllowedHTTPS(url),
                   url.lastPathComponent == "FlowDictate-\(releaseVersion).zip" {
                    downloadURL = url
                    lastStatus = "Update \(availableVersion ?? "") available."
                    if openWhenAvailable {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    downloadURL = nil
                    lastStatus = "Update found but download URL is not allowed."
                    DiagnosticsLogger.shared.log(
                        "update: rejected enclosure url=\(best.enclosureURL?.absoluteString ?? "nil")"
                    )
                }
            } else {
                lastStatus = "You’re up to date (\(current))."
            }
        } catch {
            // Feed not deployed yet is expected during early development.
            lastStatus = "Could not reach update feed. \(error.localizedDescription)"
            DiagnosticsLogger.shared.log("update check failed: \(error.localizedDescription)")
        }
    }

    func openDownloadIfAvailable() {
        guard let downloadURL, Self.isAllowedHTTPS(downloadURL) else { return }
        NSWorkspace.shared.open(downloadURL)
    }

    /// Only https URLs on the product update host (or its subdomains).
    static func isAllowedHTTPS(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if allowedHosts.contains(host) { return true }
        // Allow subdomains of flowdictate.app
        if host.hasSuffix(".flowdictate.app") { return true }
        return false
    }
}

// MARK: - Appcast

struct AppcastItem {
    var titleVersion: String
    var sparkleVersion: String?
    var sparkleShortVersion: String?
    var enclosureURL: URL?
    var isPrerelease: Bool
}

enum AppcastParser {
    static func parse(_ data: Data) -> [AppcastItem] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        var items: [AppcastItem] = []

        // Split on <item> blocks — good enough for standard Sparkle appcasts.
        let blocks = xml.components(separatedBy: "<item>").dropFirst()
        for block in blocks {
            let body = block.components(separatedBy: "</item>").first ?? block
            let title = firstMatch(#"<title>\s*([^<]+)\s*</title>"#, in: body)
            let sparkleVersion = attribute("sparkle:version", in: body)
                ?? firstMatch(#"<sparkle:version>\s*([^<]+)\s*</sparkle:version>"#, in: body)
            let shortVersion = attribute("sparkle:shortVersionString", in: body)
            let urlString = attribute("url", in: body)
            let enclosureURL = urlString.flatMap(URL.init(string:))
            let titleVersion = shortVersion
                ?? sparkleVersion
                ?? extractVersion(from: title ?? "")
                ?? "0"
            let lower = (title ?? "").lowercased()
            let isPrerelease = lower.contains("beta") || lower.contains("alpha") || lower.contains("rc")
                || (sparkleVersion?.contains("-") ?? false)
            items.append(
                AppcastItem(
                    titleVersion: titleVersion,
                    sparkleVersion: sparkleVersion ?? shortVersion,
                    sparkleShortVersion: shortVersion,
                    enclosureURL: enclosureURL,
                    isPrerelease: isPrerelease
                )
            )
        }
        return items
    }

    static func compareVersions(_ lhs: String?, _ rhs: String) -> ComparisonResult {
        let a = lhs ?? "0"
        return a.compare(rhs, options: .numeric)
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        // Matches name="value" on enclosure / sparkle tags.
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\(escaped)=\"([^\"]+)\""
        return firstMatch(pattern, in: text)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractVersion(from title: String) -> String? {
        firstMatch(#"(\d+(?:\.\d+)+)"#, in: title)
    }
}

private extension Array where Element == AppcastItem {
    func best(includePrereleases: Bool) -> AppcastItem? {
        let filtered = includePrereleases ? self : filter { !$0.isPrerelease }
        return filtered.max { a, b in
            AppcastParser.compareVersions(
                a.sparkleShortVersion ?? a.titleVersion,
                b.sparkleShortVersion ?? b.titleVersion
            ) == .orderedAscending
        }
    }
}
