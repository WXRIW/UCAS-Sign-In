import Foundation

@MainActor
final class UpdateCoordinator: ObservableObject {
    enum Presentation: Identifiable {
        case release(GitHubRelease)
        case current
        case failed

        var id: String {
            switch self {
            case .release(let release): "release-\(release.tag)"
            case .current: "current"
            case .failed: "failed"
            }
        }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    @Published var presentation: Presentation?
    @Published private(set) var isChecking = false
    private let defaults: UserDefaults
    private let checkedAtKey = "update.checkedAt"
    private let checkedVersionKey = "update.checkedVersion"
    private let promptedReleaseKey = "update.promptedRelease"
    static let automaticChecksKey = "update.automaticChecks"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func checkAutomatically() async {
        if defaults.object(forKey: Self.automaticChecksKey) as? Bool == false { return }
        if let checkedAt = defaults.object(forKey: checkedAtKey) as? Date,
           defaults.string(forKey: checkedVersionKey) == Self.currentVersion,
           case let elapsed = Date().timeIntervalSince(checkedAt),
           elapsed >= 0, elapsed < 24 * 60 * 60 { return }
        await check(manual: false)
    }

    func checkManually() async { await check(manual: true) }

    private func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defaults.set(Date(), forKey: checkedAtKey)
        defaults.set(Self.currentVersion, forKey: checkedVersionKey)
        defer { isChecking = false }
        do {
            guard let release = try await GitHubReleaseChecker.check(currentVersion: Self.currentVersion) else {
                if manual { presentation = .current }
                return
            }
            let releaseIdentity = "\(Self.currentVersion)|\(release.tag)"
            if !manual, defaults.string(forKey: promptedReleaseKey) == releaseIdentity { return }
            defaults.set(releaseIdentity, forKey: promptedReleaseKey)
            presentation = .release(release)
        } catch {
            if manual { presentation = .failed }
        }
    }
}
