import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CleanerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Keep SpringBoard and Jetsam reports", isOn: $model.keepSpringBoard)
                    Toggle("Close apps before clearing their caches", isOn: $model.closeApps)
                } header: {
                    Text("Cleaning")
                } footer: {
                    Text("Keeping those reports helps when you're debugging tweaks or resprings.")
                }

                Section {
                    Toggle("Trim logs automatically", isOn: Binding(
                        get: { model.autoTrim == .on },
                        set: { model.setAutoTrim($0) }
                    ))
                    .disabled(model.autoTrim == .unavailable || model.autoTrim == .unknown)
                } header: {
                    Text("System logs")
                } footer: {
                    Text(autoTrimFooter)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Install with", value: "TrollStore")
                } header: {
                    Text("About")
                } footer: {
                    Text("Caz uses a small root helper to measure and delete files. It only removes caches, temp files, logs and leftover installers. Photos, messages and music are never touched.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.abyss)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.lagoon)
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
