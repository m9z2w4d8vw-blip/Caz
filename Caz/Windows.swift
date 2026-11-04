import SwiftUI
import UIKit

// Windows open in the middle of the screen over the dimmed backdrop, like Dopamine's
// Settings window (DONavigationController, DOPSListController, DOHeaderCell).

struct WindowCard<Content: View>: View {
    let title: String
    let onBack: (() -> Void)?
    let content: Content

    init(title: String, onBack: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 50)
                if let onBack {
                    HStack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.foreground)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(MenuButtonStyle())
                        .accessibilityLabel("Back")
                        Spacer()
                    }
                    .padding(.leading, 8)
                }
            }
            .frame(height: 57)
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 20)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct CategoriesWindow: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        WindowCard(title: "Categories") {
            List {
                Section {
                    ForEach(model.categories) { category in
                        CategoryRow(model: model, category: category)
                            .windowRow()
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } footer: {
                    Text("Sizes appear after a scan. Maps tiles and leftover installers start off.")
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .windowList()
        }
    }
}

/// Two lines beside the switch: the name, then the size and what the category is.
struct CategoryRow: View {
    @ObservedObject var model: CleanerModel
    let category: CleanCategory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                caption
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(category.title, isOn: Binding(
                get: { category.enabled },
                set: { model.setEnabled(category.id, $0) }
            ))
            .labelsHidden()
            .disabled(model.isBusy)
        }
    }

    /// "2.6 GB · Diagnostic log archive" after a scan, just the description before one.
    private var caption: Text {
        let detail = Text(category.detail).foregroundColor(Color.white.opacity(0.55))
        guard let bytes = model.displayBytes(for: category) else { return detail }
        return Text(CleanerModel.format(bytes)).foregroundColor(Color.white.opacity(bytes > 0 ? 0.85 : 0.45))
            + Text(" · ").foregroundColor(Color.white.opacity(0.35))
            + detail
    }
}

struct AppsWindow: View {
    @ObservedObject var model: CleanerModel

    var body: some View {
        WindowCard(title: "App Caches") {
            if model.apps.isEmpty && model.skippedApps.isEmpty {
                Text(model.phase == .idle ? "Scan first to see each app's cache." : "No app caches to clean.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(model.apps) { app in
                            Toggle(isOn: Binding(
                                get: { !model.excluded.contains(app.id) },
                                set: { model.setExcluded(app.id, !$0) }
                            )) {
                                HStack(spacing: 12) {
                                    AppIconView(bundleID: app.id)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(app.id)
                                            .font(.caption2)
                                            .foregroundStyle(Color.white.opacity(0.5))
                                            .lineLimit(1)
                                        if !app.note.isEmpty {
                                            Text(app.note)
                                                .font(.caption2)
                                                .foregroundStyle(Theme.accent.opacity(0.9))
                                        }
                                    }
                                    Spacer(minLength: 6)
                                    Text(CleanerModel.format(app.bytes))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(Color.white.opacity(0.85))
                                }
                            }
                            .windowRow()
                        }
                    } footer: {
                        Text("Turn off apps whose caches you want to keep.")
                            .foregroundStyle(Color.white.opacity(0.5))
                    }

                    if !model.skippedApps.isEmpty {
                        Section {
                            ForEach(model.skippedApps) { app in
                                HStack(spacing: 12) {
                                    AppIconView(bundleID: app.id)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(app.reason)
                                            .font(.caption2)
                                            .foregroundStyle(Color.white.opacity(0.5))
                                    }
                                    Spacer(minLength: 6)
                                    Text(CleanerModel.format(app.bytes))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(Color.white.opacity(0.5))
                                }
                                .windowRow()
                            }
                        } header: {
                            Text("Skipped")
                                .foregroundStyle(Color.white.opacity(0.6))
                        } footer: {
                            Text("These apps keep downloads in their cache, so Caz never touches them.")
                                .foregroundStyle(Color.white.opacity(0.5))
                        }
                    }
                }
                .windowList()
            }
        }
    }
}

/// The app's real icon, so you can tell exactly whose cache you're clearing.
struct AppIconView: View {
    let bundleID: String

    var body: some View {
        Group {
            if let image = AppIconCache.icon(for: bundleID) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: bundleID == "extensions" ? "puzzlepiece.extension" : "app.dashed")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.foreground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.08))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 34 * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Icons are looked up once per app and kept for the rest of the session.
enum AppIconCache {
    private static var icons: [String: UIImage] = [:]
    private static var missing: Set<String> = []

    static func icon(for bundleID: String) -> UIImage? {
        if bundleID == "extensions" || missing.contains(bundleID) { return nil }
        if let icon = icons[bundleID] { return icon }
        if let icon = CazAppIcon(bundleID) {
            icons[bundleID] = icon
            return icon
        }
        missing.insert(bundleID)
        return nil
    }
}

struct SettingsWindow: View {
    @ObservedObject var model: CleanerModel
    let openLog: () -> Void

    var body: some View {
        WindowCard(title: "Settings") {
            List {
                Section {
                    Toggle("Keep SpringBoard and Jetsam Reports", isOn: $model.keepSpringBoard)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .windowRow()
                    Toggle("Close Apps Before Clearing Caches", isOn: $model.closeApps)
                        .font(.system(size: 15))
                        .foregroundStyle(.white)
                        .windowRow()
                } header: {
                    Text("Cleaning")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                }

                Section {
                    Toggle("Trim Logs Automatically", isOn: Binding(
                        get: { model.autoTrim == .on },
                        set: { model.setAutoTrim($0) }
                    ))
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .disabled(model.autoTrim == .unavailable || model.autoTrim == .unknown)
                    .windowRow()
                } header: {
                    Text("System Logs")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.6))
                } footer: {
                    Text(autoTrimFooter)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                }

                Section {
                    Button(action: openLog) {
                        HStack {
                            Text("View Log")
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuButtonStyle())
                    .windowRow()
                } footer: {
                    Text("Every line from the last scan or clean, and Export Tree at the bottom.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .windowList()
        }
    }

    private var autoTrimFooter: String {
        switch model.autoTrim {
        case .unavailable:
            return "Needs a Dopamine jailbreak. It adds a background job that keeps only the last day of logs."
        case .unknown:
            return "Checking…"
        case .on, .off:
            return "Every 6 hours, log files older than a day are deleted, so the archive never holds more than about a day's worth."
        }
    }
}

struct LogWindow: View {
    @ObservedObject var model: CleanerModel
    let onBack: () -> Void
    let onExport: () -> Void

    var body: some View {
        WindowCard(title: "Log", onBack: onBack) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.log.isEmpty {
                        Text("Nothing yet. Run a scan first.")
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("!") ? Theme.failure : Color.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // After the last line, so it shows once you've scrolled all the way down.
                    ActionButton(title: "Export Tree", symbol: "square.and.arrow.down",
                                 enabled: !model.isBusy, action: onExport)
                        .frame(height: 50)
                        .padding(.top, 20)
                    Text("Lists every file and folder on your iPhone with its size, like du -ak / over SSH, and saves it to On My iPhone › Caz.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .padding(.top, 4)
                }
                .textSelection(.enabled)
                .padding(16)
            }
        }
    }
}
