import SwiftUI

struct ContentView: View {
    @StateObject private var model = CleanerModel()
    @State private var showSettings = false
    @State private var showApps = false
    @State private var panel: Panel = .clean

    enum Panel: String, CaseIterable, Identifiable {
        case clean = "Clean"
        case log = "Log"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Backdrop()
            VStack(alignment: .leading, spacing: 16) {
                header
                if let problem = model.problem {
                    ProblemBanner(text: problem)
                }
                card
                SweepButton(model: model)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .tint(Theme.lagoon)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showApps) {
            AppListView(model: model)
        }
        .onAppear { model.onAppear() }
        .onChange(of: model.phase) { _, phase in
            withAnimation(.easeInOut(duration: 0.25)) {
                switch phase {
                case .scanning, .cleaning: panel = .log
                case .scanned: panel = .clean
                default: break
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Caz")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .tracking(-1.5)
                    .foregroundStyle(.white)
                Text(freeLine)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
        }
    }

    private var freeLine: String {
        let free = CleanerModel.format(model.freeBytes) + " free"
        if case .done(let freed) = model.phase, freed > 0 {
            return free + " (+" + CleanerModel.format(freed) + ")"
        }
        return free
    }

    private var card: some View {
        VStack(spacing: 12) {
            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)

            if panel == .clean {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, category in
                            if index > 0 {
                                Divider().overlay(Color.white.opacity(0.08))
                            }
                            CategoryRow(
                                category: category,
                                bytes: model.displayBytes(for: category),
                                isOn: Binding(
                                    get: { category.enabled },
                                    set: { model.setEnabled(category.id, $0) }
                                ),
                                onDetail: category.id == "appcache" && !model.apps.isEmpty ? { showApps = true } : nil
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .disabled(model.isBusy)
            } else {
                LogConsole(lines: model.log)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}
