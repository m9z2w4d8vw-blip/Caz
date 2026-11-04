import Combine
import Foundation

struct CleanCategory: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var enabled: Bool = true
    var bytes: Int64? = nil
    var files: Int = 0
}

struct AppCache: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: Int64
}

enum Phase: Equatable {
    case idle
    case scanning
    case scanned
    case cleaning
    case done(freed: Int64)
}

enum AutoTrimState: Equatable {
    case unknown, unavailable, on, off
}

/// Drives the UI and talks to `cazhelper`, the root helper bundled inside the app.
final class CleanerModel: ObservableObject {
    static let catalog: [CleanCategory] = [
        CleanCategory(id: "logs", title: "System logs",
                      detail: "The diagnostic log archive. It refills over a few days.",
                      symbol: "doc.text.magnifyingglass"),
        CleanCategory(id: "downloads", title: "Abandoned downloads",
                      detail: "Temp files from downloads that never finished.",
                      symbol: "arrow.down.circle"),
        CleanCategory(id: "crash", title: "Crash reports",
                      detail: "Old crash, hang and analytics reports.",
                      symbol: "exclamationmark.triangle"),
        CleanCategory(id: "syscache", title: "System caches",
                      detail: "Symbol, Memoji and thumbnail caches, plus temp copies.",
                      symbol: "gearshape.2"),
        CleanCategory(id: "appcache", title: "App caches",
                      detail: "Each app's cache and temp folders.",
                      symbol: "square.stack.3d.up"),
        CleanCategory(id: "previews", title: "Messages previews",
                      detail: "Attachment thumbnails. Rebuilt as you scroll.",
                      symbol: "message"),
        CleanCategory(id: "maps", title: "Maps tiles",
                      detail: "Map cache. Leave off if you use offline maps.",
                      symbol: "map"),
        CleanCategory(id: "installers", title: "Leftover installers",
                      detail: "IPAs and debs left in app inboxes.",
                      symbol: "shippingbox"),
    ]

    @Published var categories: [CleanCategory] = []
    @Published var apps: [AppCache] = []
    @Published var excluded: Set<String> = []
    @Published var log: [String] = []
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0
    @Published var freeBytes: Int64 = 0
    @Published var autoTrim: AutoTrimState = .unknown
    @Published var problem: String? = nil
    @Published var keepSpringBoard: Bool = true {
        didSet { UserDefaults.standard.set(keepSpringBoard, forKey: Keys.keepSpringBoard) }
    }
    @Published var closeApps: Bool = true {
        didSet { UserDefaults.standard.set(closeApps, forKey: Keys.closeApps) }
    }

    private var freedTotal: Int64 = 0
    private var stepsDone = 0
    private var stepsTotal = 1
    private let queue = DispatchQueue(label: "com.parv.caz.helper", qos: .userInitiated)

    private enum Keys {
        static let keepSpringBoard = "keepSpringBoard"
        static let closeApps = "closeApps"
        static let excluded = "excludedApps"
        static let disabled = "disabledCategories"
    }

    init() {
        let defaults = UserDefaults.standard
        keepSpringBoard = defaults.object(forKey: Keys.keepSpringBoard) as? Bool ?? true
        closeApps = defaults.object(forKey: Keys.closeApps) as? Bool ?? true
        excluded = Set(defaults.stringArray(forKey: Keys.excluded) ?? [])
        let disabled = Set(defaults.stringArray(forKey: Keys.disabled) ?? ["maps", "installers"])
        categories = Self.catalog.map { item in
            var category = item
            category.enabled = !disabled.contains(item.id)
            return category
        }
        freeBytes = Self.currentFreeBytes()
    }

    // MARK: - Derived values

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    var appCacheBytes: Int64 {
        apps.filter { !excluded.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
    }

    func displayBytes(for category: CleanCategory) -> Int64? {
        guard let bytes = category.bytes else { return nil }
        if category.id == "appcache" && !apps.isEmpty { return appCacheBytes }
        return bytes
    }

    var selectedBytes: Int64 {
        categories.filter(\.enabled).reduce(Int64(0)) { $0 + (displayBytes(for: $1) ?? 0) }
    }

    // MARK: - Actions

    func onAppear() {
        if !FileManager.default.fileExists(atPath: helperPath) {
            problem = "The root helper is missing from the app. Rebuild Caz from the repo."
        }
        refreshAutoTrim()
    }

    func setEnabled(_ id: String, _ isOn: Bool) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].enabled = isOn
        let disabled = categories.filter { !$0.enabled }.map(\.id)
        UserDefaults.standard.set(disabled, forKey: Keys.disabled)
    }

    func setExcluded(_ id: String, _ isExcluded: Bool) {
        if isExcluded { excluded.insert(id) } else { excluded.remove(id) }
        UserDefaults.standard.set(Array(excluded), forKey: Keys.excluded)
    }

    func scan() {
        guard !isBusy else { return }
        phase = .scanning
        log.removeAll()
        apps.removeAll()
        for index in categories.indices {
            categories[index].bytes = nil
            categories[index].files = 0
        }
        begin(steps: categories.count)
        append("Scanning…")
        var args = ["scan"]
        if keepSpringBoard { args.append("--keep-sb") }
        runHelper(args) { [weak self] status in
            guard let self = self else { return }
            self.apps.sort { $0.bytes > $1.bytes }
            if status == 0 {
                self.phase = .scanned
                self.append("You can free about \(Self.format(self.selectedBytes)).")
            } else {
                self.phase = .idle
                self.append("Scan stopped (code \(status)).")
            }
        }
    }

    func clean() {
        guard phase == .scanned else { return }
        let ids = categories.filter { $0.enabled && (displayBytes(for: $0) ?? 0) > 0 }.map(\.id)
        guard !ids.isEmpty else {
            append("Turn on at least one category that has something to clean.")
            return
        }
        phase = .cleaning
        freedTotal = 0
        begin(steps: ids.count)
        var args = ["clean", ids.joined(separator: ",")]
        if keepSpringBoard { args.append("--keep-sb") }
        if closeApps { args.append("--close-apps") }
        if !excluded.isEmpty { args += ["--exclude", excluded.sorted().joined(separator: ",")] }
        append("Cleaning \(ids.count) of \(categories.count) categories…")
        runHelper(args) { [weak self] status in
            guard let self = self else { return }
            self.freeBytes = Self.currentFreeBytes()
            self.progress = 1
            self.phase = .done(freed: self.freedTotal)
            if status == 0 {
                self.append("Freed \(Self.format(self.freedTotal)).")
            } else {
                self.append("Cleaning stopped (code \(status)). Lines starting with ! show what failed.")
            }
        }
    }

    func refreshAutoTrim() {
        runHelper(["autotrim", "status"]) { _ in }
    }

    func setAutoTrim(_ isOn: Bool) {
        guard autoTrim == .on || autoTrim == .off else { return }
        runHelper(["autotrim", isOn ? "enable" : "disable"]) { _ in }
    }

    func append(_ text: String) {
        log.append(text)
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    // MARK: - Helper plumbing

    private var helperPath: String { Bundle.main.bundlePath + "/cazhelper" }

    private func runHelper(_ args: [String], completion: @escaping (Int32) -> Void) {
        let path = helperPath
        queue.async { [weak self] in
            let status = CazSpawnRoot(path, args) { line in
                DispatchQueue.main.async { self?.handle(line) }
            }
            DispatchQueue.main.async {
                if status == -1 || status == 3 {
                    self?.problem = "Caz couldn't get root access. Install it with TrollStore."
                }
                completion(status)
            }
        }
    }

    /// One line of the helper's tab-separated protocol (see RootHelper/main.c).
    private func handle(_ line: String) {
        let fields = line.components(separatedBy: "\t")
        switch fields[0] {
        case "LOG":
            append(fields.dropFirst().joined(separator: " "))
        case "ERR":
            append("! " + fields.dropFirst().joined(separator: " "))
        case "CAT" where fields.count >= 4:
            if let index = categories.firstIndex(where: { $0.id == fields[1] }) {
                categories[index].bytes = Int64(fields[2]) ?? 0
                categories[index].files = Int(fields[3]) ?? 0
            }
            step()
        case "APP" where fields.count >= 4:
            apps.append(AppCache(id: fields[1], name: fields[3], bytes: Int64(fields[2]) ?? 0))
        case "FREED" where fields.count >= 3:
            freedTotal += Int64(fields[2]) ?? 0
            if let index = categories.firstIndex(where: { $0.id == fields[1] }) {
                categories[index].bytes = 0
                categories[index].files = 0
            }
            if fields[1] == "appcache" { apps.removeAll() }
            step()
        case "AUTOTRIM" where fields.count >= 2:
            switch fields[1] {
            case "on": autoTrim = .on
            case "off": autoTrim = .off
            default: autoTrim = .unavailable
            }
        default:
            if !line.isEmpty { append(line) }
        }
    }

    private func begin(steps: Int) {
        stepsDone = 0
        stepsTotal = max(1, steps)
        progress = 0
    }

    private func step() {
        stepsDone += 1
        progress = min(1, Double(stepsDone) / Double(stepsTotal))
    }

    // MARK: - Formatting

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func currentFreeBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/private/var"),
              let free = attributes[.systemFreeSize] as? NSNumber else { return 0 }
        return free.int64Value
    }
}
