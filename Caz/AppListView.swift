import SwiftUI

struct AppListView: View {
    @ObservedObject var model: CleanerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.apps) { app in
                        Toggle(isOn: Binding(
                            get: { !model.excluded.contains(app.id) },
                            set: { model.setExcluded(app.id, !$0) }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    Text(app.id)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CleanerModel.format(app.bytes))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Turn off apps whose caches you want to keep. Spotify is always skipped because it stores downloaded music in its cache.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.abyss)
            .navigationTitle("App caches")
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
}
