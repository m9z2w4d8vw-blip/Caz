import Combine
import Foundation
import UIKit

/// One GitHub release of Caz.
struct CazRelease: Identifiable, Equatable {
    let id: Int
    let name: String
    let body: String
    let version: [Int]
    let downloadURL: URL?
}

/// Checks GitHub for a newer Caz, then downloads and installs it. Follows Dopamine's updater:
/// DOUIManager (releases and versions), DOUpdateViewController (changelog) and
/// DODownloadViewController (download and install).
final class UpdateModel: ObservableObject {
    enum Stage: Equatable {
        case changelog
        case downloading
        case installing
        case installed
        case failed(String)
    }

    static let apiURL = URL(string: "https://api.github.com/repos/m9z2w4d8vw-blip/Caz/releases")!
    static let releasesPage = URL(string: "https://github.com/m9z2w4d8vw-blip/Caz/releases")!

    /// Releases newer than this build, newest first.
    @Published private(set) var updates: [CazRelease] = []
    @Published var stage: Stage = .changelog
    /// What the circle shows. It eases toward the real progress like Dopamine's (25% of the gap per frame).
    @Published private(set) var progress: Double = 0

    private var target: Double = 0
    private var timer: Timer?
    private var task: URLSessionDownloadTask?
    private var checking = false
    private var checked = false

    var latest: CazRelease? { updates.first }
    var isAvailable: Bool { latest?.downloadURL != nil }
    var isBusy: Bool { stage == .downloading || stage == .installing }

    // MARK: - Checking

    /// Fetches the releases once. Drafts and pre-releases are ignored, as in Dopamine.
    func check() {
        guard !checking, !checked else { return }
        checking = true
        var request = URLRequest(url: Self.apiURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let releases = data.flatMap { Self.parse($0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                guard let releases = releases else { return }   // offline or rate limited: try next launch
                self.checked = true
                let current = Self.versionParts(Bundle.main.shortVersion)
                self.updates = releases
                    .filter { Self.compare($0.version, current) > 0 }
                    .sorted { Self.compare($0.version, $1.version) > 0 }
            }
        }.resume()
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
        let id: Int
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    static func parse(_ data: Data) -> [CazRelease]? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let list = try? decoder.decode([APIRelease].self, from: data) else { return nil }
        return list.compactMap { release -> CazRelease? in
            if release.draft || release.prerelease { return nil }
            let version = versionParts(release.tagName)
            if version.isEmpty { return nil }
            let package = release.assets.first(where: { $0.name.lowercased().hasSuffix(".tipa") })
                ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") })
            let title = release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName
            return CazRelease(id: release.id, name: title, body: release.body ?? "", version: version,
                              downloadURL: package.flatMap { URL(string: $0.browserDownloadUrl) })
        }
    }

    /// "v1.0.57" -> [1, 0, 57]
    static func versionParts(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // MARK: - Downloading and installing

    /// Downloads the newest Caz.tipa, then hands it to `install`. If installing fails, TrollStore is
    /// asked to install it from the link instead, like Dopamine does when it can't update itself.
    func startDownload(install: @escaping (URL, @escaping (Bool) -> Void) -> Void) {
        guard let url = latest?.downloadURL, !isBusy else { return }
        stage = .downloading
        progress = 0
        target = 0
        let downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            var saved: URL? = nil
            var problem = error?.localizedDescription
            if let location = location, error == nil {
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    problem = "GitHub answered with error \(http.statusCode)."
                } else {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let destination = folder.appendingPathComponent("Caz-update.tipa")
                    try? FileManager.default.removeItem(at: destination)
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        saved = destination
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let file = saved else {
                    self.fail(problem ?? "The download didn't finish.")
                    return
                }
                self.target = 1
                self.stage = .installing
                install(file) { [weak self] ok in
                    guard let self = self else { return }
                    if ok {
                        self.stage = .installed
                    } else {
                        self.openInTrollStore()
                    }
                }
            }
        }
        task = downloadTask
        downloadTask.resume()
        startTimer()
    }

    /// 60 times a second: read the real progress and move the circle a quarter of the way there.
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] tick in
            guard let self = self else {
                tick.invalidate()
                return
            }
            if self.progress >= 0.99 {
                self.progress = 1
                tick.invalidate()
                return
            }
            if let task = self.task, task.countOfBytesExpectedToReceive > 0 {
                let real = Double(task.countOfBytesReceived) / Double(task.countOfBytesExpectedToReceive)
                self.target = max(self.target, real)
            }
            if self.progress < self.target {
                self.progress += (self.target - self.progress) * 0.25
            }
        }
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        stage = .failed(message)
    }

    /// TrollStore installs from a link with apple-magnifier://install?url=, the same hand-off Dopamine
    /// uses. Without TrollStore, the releases page opens instead.
    func openInTrollStore() {
        guard let url = latest?.downloadURL,
              let link = URL(string: "apple-magnifier://install?url=" + url.absoluteString) else {
            UIApplication.shared.open(Self.releasesPage)
            return
        }
        UIApplication.shared.open(link, options: [:]) { opened in
            if !opened { UIApplication.shared.open(UpdateModel.releasesPage) }
        }
    }

    /// Back to the changelog when the window closes, unless something is still running.
    func resetIfIdle() {
        if !isBusy { stage = .changelog }
    }
}
