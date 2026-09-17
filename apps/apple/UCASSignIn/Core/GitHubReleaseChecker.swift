import Foundation

public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = normalized.hasPrefix("v") ? String(normalized.dropFirst()) : normalized
        let components = text.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components[0] == "0" || !components[0].hasPrefix("0"),
              components[1] == "0" || !components[1].hasPrefix("0"),
              components[2] == "0" || !components[2].hasPrefix("0"),
              let major = Int(components[0]),
              let minor = Int(components[1]), let patch = Int(components[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct GitHubRelease: Identifiable, Sendable {
    public var id: String { tag }
    public let version: ReleaseVersion
    public let tag: String
    public let url: URL
}

public enum GitHubReleaseChecker {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/WXRIW/UCAS-Sign-In/releases/latest")!

    public static func check(currentVersion: String, session: URLSession = .shared) async throws -> GitHubRelease? {
        guard let installed = ReleaseVersion(currentVersion) else { throw ReleaseCheckError.invalidCurrentVersion }
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("UCAS-Sign-In-Update-Checker", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ReleaseCheckError.requestFailed }
        return try parse(data: data, installed: installed)
    }

    static func parse(data: Data, installed: ReleaseVersion) throws -> GitHubRelease? {
        let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        guard let latest = ReleaseVersion(payload.tagName) else { throw ReleaseCheckError.invalidRelease }
        guard payload.htmlURL.scheme == "https", payload.htmlURL.host?.lowercased() == "github.com",
              payload.htmlURL.path.lowercased().hasPrefix("/wxriw/ucas-sign-in/") else {
            throw ReleaseCheckError.invalidRelease
        }
        return latest > installed ? GitHubRelease(version: latest, tag: "v\(latest)", url: payload.htmlURL) : nil
    }

    private struct ReleasePayload: Decodable {
        let tagName: String
        let htmlURL: URL
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}

enum ReleaseCheckError: Error {
    case invalidCurrentVersion
    case requestFailed
    case invalidRelease
}
